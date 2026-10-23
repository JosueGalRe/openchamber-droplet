//
//  VoiceReply.swift
//  Openchamber
//
//  Talking to a session from the notch: the microphone into the system's
//  speech recognizer, on this Mac when it can, and the words as they come.
//  The shelf only gives the keyboard to a widget that takes it on every open,
//  so this is how a session gets an answer without a window.
//

import AVFoundation
import Speech

@MainActor
final class VoiceCapture {
    /// The longest a dictation runs before it stops on its own.
    static let limit: TimeInterval = 60

    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private let onText: @MainActor (String) -> Void
    private let onEnd: @MainActor () -> Void

    var isRunning: Bool { engine.isRunning }

    init(onText: @escaping @MainActor (String) -> Void, onEnd: @escaping @MainActor () -> Void) {
        self.onText = onText
        self.onEnd = onEnd
    }

    /// Starts listening. The caller has the microphone and speech permissions
    /// from the host already: asking Speech without them can end the process.
    func start() throws {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { throw VoiceError.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let input = engine.inputNode
        // The tap runs on the audio thread; the request is safe to feed from there.
        nonisolated(unsafe) let feed = request
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            feed.append(buffer)
        }
        engine.prepare()
        try engine.start()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || result?.isFinal == true
            Task { @MainActor in
                if let text { self?.onText(text) }
                if done { self?.stop() }
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.limit))
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        guard engine.isRunning || task != nil else { return }
        timeout?.cancel()
        timeout = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        task?.finish()
        task = nil
        onEnd()
    }
}

enum VoiceError: Error {
    case unavailable
}
