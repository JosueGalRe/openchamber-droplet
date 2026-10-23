//
//  Watchers.swift
//  Openchamber
//
//  What the droplet notices about the Mac rather than about OpenChamber:
//  when you step away and come back, and when you copy an error.
//

import AppKit
import Combine

/// Says when you leave the Mac and when you are back: the screen locks or
/// sleeps, or nothing is touched for ten minutes.
@MainActor
final class AwayWatcher {
    /// How long without input counts as away when the screen stays on.
    static let idleThreshold: TimeInterval = 10 * 60

    private(set) var awaySince: Date?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var poll: AnyCancellable?
    private let onReturn: @MainActor (_ since: Date) -> Void

    init(onReturn: @escaping @MainActor (_ since: Date) -> Void) {
        self.onReturn = onReturn
    }

    func start() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        for (center, name, away) in [
            (distributed, Notification.Name("com.apple.screenIsLocked"), true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), false),
            (workspace, NSWorkspace.screensDidSleepNotification, true),
            (workspace, NSWorkspace.screensDidWakeNotification, false),
        ] as [(NotificationCenter, Notification.Name, Bool)] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { away ? self?.leave(at: Date()) : self?.back() }
            }
            observers.append((center, token))
        }
        // Stepping away without locking: no input for ten minutes, then any.
        poll = Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] now in
            // ~0 is any input, keyboard, pointer or otherwise.
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .null)
            if idle >= Self.idleThreshold { self?.leave(at: now.addingTimeInterval(-idle)) } else if idle < 30 { self?.back() }
        }
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        poll?.cancel()
        poll = nil
        awaySince = nil
    }

    private func leave(at date: Date) {
        if awaySince == nil { awaySince = date }
    }

    private func back() {
        guard let since = awaySince else { return }
        awaySince = nil
        onReturn(since)
    }
}

/// Offers what you copy when it reads like an error. Polls the pasteboard's
/// change count, which costs nothing, and reads the text only when it changed.
@MainActor
final class ClipboardWatcher {
    private var poll: AnyCancellable?
    private var lastChange = NSPasteboard.general.changeCount
    private let onError: @MainActor (String) -> Void

    init(onError: @escaping @MainActor (String) -> Void) {
        self.onError = onError
    }

    func start() {
        guard poll == nil else { return }
        lastChange = NSPasteboard.general.changeCount
        poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.check() }
    }

    func stop() {
        poll?.cancel()
        poll = nil
    }

    private func check() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount
        // Password managers mark what they copy; it is never read.
        let types = pasteboard.types ?? []
        guard !types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")),
              !types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")),
              let text = pasteboard.string(forType: .string), ErrorText.looksLikeError(text) else { return }
        onError(text)
    }
}

enum ErrorText {
    /// Whether copied text is an error worth handing to an agent: a stack
    /// frame, a compiler diagnostic or an `…Error:` line, not prose that
    /// happens to say "error".
    static func looksLikeError(_ text: String) -> Bool {
        guard (15...50_000).contains(text.count) else { return false }
        let patterns = [
            #"(?m)^\s*at .+[:(]\d+(:\d+)?\)?\s*$"#,             // JavaScript, Java and Swift stack frames
            #"(?m)^\s*File ".+", line \d+"#,                    // Python tracebacks
            #"(?m)^Traceback \(most recent call last\)"#,
            #"(?m)^[\w.]*(Error|Exception)(\[\w+\])?: "#,       // TypeError: …, ValueError: …
            #"(?m)^error(\[E\d+\])?: |error TS\d+: "#,          // rustc, tsc
            #"(?m):\d+:\d+: (fatal )?error: "#,                 // clang, swiftc, gcc
            #"(?m)^panic: |^Fatal error: |^thread '.+' panicked at"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}
