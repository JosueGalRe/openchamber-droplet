# OpenChamber, a Droplet for Droppy

<!-- Written by `droppykit agent`. Add your own notes below; the file is only rewritten with --force. -->

This package is a **Droplet**: an extension that runs inside Droppy, the
Dynamic Island and shelf for Mac, written in SwiftUI against **DroppyKit**.
Droppy loads the built `.droplet` bundle into its own process and draws it on
the notch, the shelf, the lock screen and the menu bar.

- Droplet id: `openchamber`. It is also `OpenchamberDroplet.id` in Swift and `id` in `droplet.json`; the three must agree or the loader refuses the bundle.
- Swift product: `Openchamber`, a dynamic library. The harness target is `OpenchamberHarness`.
- SDK checkout: `/Users/josuegalre/projects/personal/droppykit` (DroppyKit 1.22.0). Docs online: https://getdroppy.app/docs/droppykit
- Host: Droppy 15.3 or later, which runs an unsigned bundle once its user approves that build under Settings, Store, Local droplets and asks again each time it opens, or the free Droppy Playground (https://getdroppy.app/download/playground), which loads unsigned bundles without asking.

## The loop

Every change goes through all of this, in order. A droplet can compile,
validate and then draw nothing, so a green build is not the end.

1. Edit `Sources/Openchamber/`. The manifest is `droplet.json`.
2. `droppykit build` writes `.build/Openchamber.droplet`, universal, linked against the
   framework Droppy ships. Never a bare `swift build` for the bundle: it folds a second
   copy of DroppyKit into the droplet, and that bundle loads in the harness and dies
   inside Droppy at dyld with "Symbol not found".
3. `droppykit validate` runs the exact checks the Store's intake runs.
4. `droppykit run -- --shots ./shots --report ./shots/report.json` renders every surface
   to a PNG without opening a window and writes a JSON verdict. Look at the pictures.
   Read `report.json`: `problems` must be empty and every surface you declared must be
   `provided`.
5. Put the bundle into Droppy Playground and confirm it loaded. Copy
   `.build/Openchamber.droplet` to
   `~/Library/Application Support/Droppy Playground/Droplets/openchamber/Openchamber.droplet`,
   relaunch the Playground, and read its Store row: the subtitle is the loader's verdict.

With the DroppyKit MCP server connected, the same steps are the tools `droppykit_build`,
`droppykit_validate`, `droppykit_shots` and `droppykit_install`, and `droppykit_shots`
returns the images inline. This package carries the server in `.mcp.json` (Claude Code)
and `.cursor/mcp.json` (Cursor). Codex: `codex mcp add droppykit -- /Users/josuegalre/projects/personal/droppykit/Scripts/droppykit mcp`.
The other tools are `droppykit_manifest` (a static check, no build), `droppykit_docs`
(the guides and a search over the SDK sources), `droppykit_doctor`, `droppykit_new`,
`droppykit_open_harness` and `droppykit_submit`.

`droppykit run` with no arguments opens the harness window for a person: Droppy's own
Settings panel with a page per surface. You cannot see that window. The shots are your
eyes; take them after every visual change.

`droppykit version` says which SDK checkout the scripts come from and which tag this
package pins; `droppykit update` moves both to the newest release. A build that stops with
"no compiled objects" or "DroppyKit.o not found" is an SDK older than 1.2.1: update it.

## Rules

- **Surfaces and conformances agree.** `surfaces` in `droplet.json` lists what the droplet
  provides; the droplet conforms to the matching protocol for each of them and to nothing it
  does not list. Disagreement is the most common reason a droplet validates and then does
  nothing.
- **Every shelf widget declares both widths.** `preferredSoloWidth` and
  `preferredPairedWidth` are required; Droppy refuses a descriptor that leaves either to a
  host fallback. Solo and paired are different compositions, not one view at two widths:
  branch on `context.isPaired`.
- **Layout traits describe the widget's rectangle.** Every number in
  `ShelfWidgetLayoutTraits` is the area the widget draws in, in points at the Regular shelf
  size, exactly what the harness renders; Droppy adds its own chrome around it. `.fixed(150)`
  is a 150-point rectangle, alone and in a row, clamped to 48 through 480. A widget that needs
  more height declares more; it never pads its way out of a clip. A solo widget is never
  narrower than 352 on a notch or 370 on an island (the camera island's included), so lay out
  to `context.availableSize`.
- **No card, no border around the widget.** Droppy paints nothing behind a widget and almost
  every one of its own widgets lays its content directly on the shelf's black. Put no
  background, fill, outline or rounded box on the widget's root view. `notchSurfaceCardFill`
  is for a tile or a chip inside the widget that has to read as raised, never a frame.
- **Lay the widget out like Droppy's.** The root view fills the rectangle
  (`.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)`) with ONE
  padding, `.padding(context.contentInsets)`, and nothing on top of it. It clears the host's
  rounded clip: 8 on every edge alone under a notch (the 18pt card corner), 0 alone on the
  island and the camera island, where the island shell clips the card and keeps one even gap,
  and 0 on every edge in
  a grouped row and while the widget is wrapped around the camera (the host clips both square).
  In a row every widget shares one top line, one bottom line and one gap to the divider: your
  first row on the rectangle's top edge, your last row on its bottom edge, and one
  `Spacer(minLength: 0)` between them for the extra height a taller neighbour gives the row,
  never centring the composition in it (`minAPI` 1.21.0). The shelf's chrome already
  inset the rectangle (17.5pt from the shell's walls and floor), so never add your own padding
  or corner inset on top: it doubles the gap.
  Leading text, trailing `.monospacedDigit()` numbers, rows that span the
  full width, a header row of a 12pt symbol and a 12pt semibold title with the widget's control
  at its trailing end, `DroppySpacing` steps between rows. Declare the height the content
  needs; never leave unused space or fill it with padding.
- **The physical notch is cleared for you, except on a HUD strip.** The shelf, a takeover,
  a HUD card and a live activity are inset past the camera housing by the host; never pad for
  it. A HUD strip is handed the whole width across the housing: put its content at the two
  outer edges and nothing in the middle (`host.environment.notchGeometry.closedWidth` is the
  housing), the way the World Clock example's strip does. Never centre a strip.
- **The camera island is the third shape.** The MacBook Pro with an OLED display has a camera
  pill a few points below the edge instead of a notch (`notchGeometry.cutout` is
  `.cameraIsland`, `closedWidth` × `closedHeight` the pill, 59 × 31 on the 16-inch,
  `cutoutTopInset` its 8.5pt gap, `isHardwareNotch` true; `minAPI` 1.22.0 to read `cutout`,
  `cutoutTopInset`, `compactRowHeight` or `compactShell`). Droppy is always the island there (`context.surface` is `.dynamicIsland`), sitting on
  the pill: the host splits compact content into wings around it exactly as around a notch,
  in a 31pt capsule, and clears it above every card and shelf. Never frame an accessory or a
  strip to `DroppyLiveActivityMetrics.rowHeight`: read `rowHeight(on: notchGeometry)`, the row
  the host really draws on that display (`notchGeometry.compactRowHeight`: a 32pt Air notch,
  the pill, the island with the user's offset), and branch a compact picture on
  `notchGeometry.compactShell` (`.notchWings`, `.islandCapsule`, `.islandWings`), never on
  `isHardwareNotch`. A strip that keeps `closedWidth` free in its middle is right there
  unchanged. Check every surface on the harness's Camera island stages.
- **Droppy owns every motion around your surfaces; you animate only what you swap.** A live
  activity row and a HUD are mounted exactly like Droppy's own, so never put an entrance
  transition on the view a factory returns (it plays twice). A live activity is compact only:
  hovering or clicking it opens the shelf, `makeExpanded` is not mounted, and Stop / Start
  belong in the shelf widget. A glyph, label or control you swap while a surface is up takes
  `DroppyTransition.compactContent` in a wing or strip and `DroppyTransition.element` in a
  card, never a transition or spring of your own (`minAPI` 1.8.0).
- **Wrap the header row around the camera, notch or camera island.** Opt every solo widget
  with a header row in:
  `ShelfWidgetLayoutTraits(..., notchWrap: ShelfWidgetNotchWrapTraits(headerHeight:minimumBandWidth:))`
  with the classic row's height. When `context.notchWrap` is set, draw the row with
  `ShelfWidgetNotchWrapRow(wrap) { leading } trailing: { trailing }`, Droppy's own wrapped row
  (each half pinned to its band, the row `wrap.headerHeight` tall; `minAPI` 1.22.0), and start
  everything else under it.
  Nothing between the halves (that is under the camera); a title that does not fit drops its
  words (`ViewThatFits`). Never offset or pad the row yourself. When it is `nil`, draw the
  classic header (`minAPI` 1.21.0). On the camera island (1.22.0) the context is an island card's
  (`.dynamicIsland`, `usesIslandCurvature`) and still carries the wrap: read `notchWrap`, never
  the surface.
- **Every control in a widget is Droppy's flat wash.** `DroppyWashCircleButtonStyle` for a
  symbol, `DroppyWashPillButtonStyle` for a label, `.neutral` for everything but the one action
  the widget is for, which takes `.accent(color)`. 34pt alone on the shelf, 28pt beside another
  widget and in the row wrapped beside the camera, 24pt for a small choice or a control inside
  a list row (`DroppyWashSize`; `context.washControlSize` is the header's and the last row's for
  the mount in hand, never a number of your own). A two- or three-way switch is
  `DroppyWashChoiceButtonStyle` (Pomodoro's Focus / Break pills, `DroppyWashChoiceButtonStyle.spacing`
  apart), never a segmented `Picker` or two buttons trading styles; a `Menu`'s label is
  `.droppyWashCircle(diameter:...)`. Pass `context.usesAdaptiveForegrounds`. One family per
  widget: never glass and wash together, never a bordered chip, a white button or a wash of
  your own (`minAPI` 1.21.0 for the disc and the pill, 1.22.0 for `DroppyWashSize`,
  `washControlSize`, the choice pills, the stretched pill and the menu disc). A widget with controls takes no clicks mid-spring:
  `.allowsHitTesting(!context.isShelfTransitioning)` at its root.
  Not buttons: tiles that are the widget's content keep their look, a live activity row keeps
  `DroppyLiveActivityControlStyle`, and a settings pane uses native macOS controls.
- **Your icon follows the user's icon style by itself.** Droppy draws the compiled icon in
  Default, Clear or Tinted, light or dark; design its `dark` and `tinted` fills in Icon
  Composer and change nothing in code. A view that must match reads the `\.droppyIconStyle`
  environment value and falls back to `DroppyIconStyleObserver.shared.style` (`minAPI` 1.21.0).
- **The menu bar extra is Droppy's.** Conform to `MenuBarExtraProviding` and never create an
  `NSStatusItem` yourself: Droppy shows the extra as a tile in its Command Center (the panel
  under Droppy's menu bar icon) and cannot order, hide or remove an item it did not create.
  `makeMenuBarExtra()` is called again whenever the droplet's `objectWillChange` fires or one
  of its `host.preferences` keys changes, so a "Show in Command Center" switch applies at
  once; return `nil` to take the tile away.
- **What you offer follows a broadcast, never a relaunch.** `widgetDescriptors`, and the
  `expandedSurfaceSize` of a surface that is up, are read again whenever the droplet's
  `objectWillChange` fires or one of its `host.preferences` keys changes, at most about four
  times a second. A widget can stay out of the list until it is configured and appear the
  moment it is; one you stop declaring leaves the shelf and keeps the user's placement. State
  in another object (a model, a session) must forward its `objectWillChange` to the droplet's
  own or be stored in `host.preferences`: Droppy hears nothing else. A presented surface keeps
  the descriptor it was presented with, and a broadcast never dismisses it, so dismiss it
  before you take its provider away.
- **Everything `activate(host:)` starts, `deactivate()` stops.** Timers, observers, tasks,
  connections. Swift cannot unload code, so anything left running runs until Droppy
  relaunches.
- **A widget the user watches holds the shelf open while it runs.** The shelf closes when the
  pointer leaves it; a teleprompter, countdown or live transcript calls
  `host.shelf.setHoldsOpen(true)` when its work starts and `false` the moment it ends
  (`shelf-write`, `minAPI` 1.5.0). A widget with nothing to show until it is configured sends
  the user to its settings pane with `host.workspace.openSettings()`, and asks for permissions
  there through `host.permissions`, never from the shelf.
- **Host calls are gated by `capabilities`.** A service call without its capability in
  `droplet.json` is refused: it returns `false` or `nil` and logs one line. Declare what you
  use and only that; the user sees the list.
- **The principal class does nothing.** `OpenchamberPrincipal` is `@objc`, is named in the
  bundle's `NSPrincipalClass`, and only creates the droplet. It runs before the host is ready.
- **No `main.swift`.** The harness entry is `@main` in
  `Sources/OpenchamberHarness/OpenchamberHarness.swift`, and a file named `main.swift` cannot
  coexist with `@main`.
- **Look like Droppy, not like a guest.** Surfaces are dark. Foreground colours come from
  `AdaptiveColors`, spacing from `DroppySpacing`, radii from `DroppyRadius` with
  `style: .continuous`. No borders or outlines, no gradients, no ALL-CAPS labels, sentence
  case everywhere, and never paint your own background on a widget. Never repeat the page
  header in a settings pane: Droppy already shows the droplet's icon, name, summary and maker
  above it, so the pane starts with its first setting (the Store refuses a pane that shows the
  droplet's own icon or its name as a title). Settings panes are rooted
  in `DropletSettingsPane` (`minAPI` 1.9.0) and built from `DropletSettingsCard`,
  `DropletSettingsSection`, `DropletControlRow`, `DropletToggleRow`, `DropletStackedRow` and
  `DropletSliderRow`; the host mounts the pane in its native grouped form, so the pane's
  content is a list of sections, never a `VStack`, and it places no dividers.
- **Never make the droplet's icon.** Jordy designs every Store droplet's icon himself, in
  Icon Composer and in Droppy's own style, so it adapts to light, dark, clear and tinted
  icons and matches the rest of the Store. `Openchamber.icon` is a placeholder for the
  harness and the Playground: never generate, draw, redesign or replace it, never add
  another `.icon`, `.icns` or app-icon image, and never change `icon` in `droplet.json`.
  `droppykit submit` leaves it out, and the Store refuses an icon that is not Jordy's. If
  the developer has an idea for the icon, write it down for the merge request's Icon concept
  section (a sentence, a reference sketch, an SF Symbol to start from). Glyphs and images
  inside the droplet's own UI are fine to make.
- **`droplet.json` is the truth for the build.** `Info.plist` is generated from it.
  `version` is numeric `major.minor.patch`; `summary` is at most 60 characters;
  `minAppVersion` stays `15.3.0` unless the droplet needs something newer; `kit.minAPI` is
  the oldest DroppyKit API the droplet actually calls. `droppykit build` fails when it is
  older than that and names the calls and the version to set; set that version, never
  lower it to get a droplet loaded.
- **Do not edit anything under `/Users/josuegalre/projects/personal/droppykit`.** That is the SDK checkout; fixes there go
  upstream. This package is where the work is.

## Where the truth is

Read these before guessing at an API. They are on disk, in the SDK checkout.

- Guides, as Markdown: `/Users/josuegalre/projects/personal/droppykit/Sources/DroppyKit/Documentation.docc/`
  `CreateYourFirstDroplet.md`, `DropletSetup.md`, `DesignGuidelines.md`, `ShelfWidgets.md`,
  `LiveActivities.md`, `ExpandedSurfaces.md`, `SettingsPanes.md`, `Icons.md`, `Harness.md`,
  `HostSupport.md`, `Playground.md`, `Submitting.md`, and `BuildWithCodingAgents.md` for this
  workflow in full.
- The surface protocols, one file each: `/Users/josuegalre/projects/personal/droppykit/Sources/DroppyKit/Capabilities/`
- The host services a droplet calls: `/Users/josuegalre/projects/personal/droppykit/Sources/DroppyKit/Services/DropletServices.swift`
  and `/Users/josuegalre/projects/personal/droppykit/Sources/DroppyKit/Core/DropletHost.swift`
- The manifest type, with every field documented: `/Users/josuegalre/projects/personal/droppykit/Sources/DroppyKit/Bundle/DropletManifest.swift`
- Design tokens and the settings components: `/Users/josuegalre/projects/personal/droppykit/Sources/DroppyKit/DesignSystem/`
- A complete droplet that uses every surface: `/Users/josuegalre/projects/personal/droppykit/Examples/WorldClock/`
- The compatibility promise and the version ledger: `/Users/josuegalre/projects/personal/droppykit/COMPATIBILITY.md`

## Surfaces

| `surfaces` value in droplet.json | Conform to | Shot |
| --- | --- | --- |
| `shelf-widget` | `ShelfWidgetProviding` | `shelf-widget.png` |
| `live-activity` | `LiveActivityProviding` | `live-activity.png` |
| `expanded-surface` | `ExpandedSurfaceProviding` | `expanded-surface.png` |
| `settings-pane` | `SettingsPaneProviding` | `settings-pane.png` |
| `hud` | `HUDPresenting` | `hud.png` |
| `lock-screen-status` | `LockScreenStatusProviding` | `lock-screen.png` |
| `menu-bar-extra` | `MenuBarExtraProviding` | `menu-bar.png` |

`overview.png` shows the identity card with a verdict pill per surface, `capabilities.png`
the capability switches, `preferences.png` every stored value, and `activity.png` every host
call in order, refused ones marked.

## Done means

- `droppykit build` and `droppykit validate` both pass.
- The report's `problems` is empty and `activation.error` is null.
- You have looked at the shot of every surface you touched.
- The bundle loaded in Droppy Playground: `droppykit_install` says loaded, or the Store row
  shows it switched on.
- `droplet.json` still describes what the code does: surfaces, capabilities, summary.

## Package layout

```
Package.swift                     product Openchamber (dynamic) and OpenchamberHarness
droplet.json                      the manifest; Info.plist is generated from it
Sources/Openchamber/              the droplet
Sources/OpenchamberHarness/       the @main harness entry; never main.swift
Openchamber.icon/                 placeholder icon for the harness; Jordy designs the real one, never edit it
Assets/Creator.png                square creator avatar, at least 256px, required
.build/Openchamber.droplet        what droppykit build writes
AGENTS.md, CLAUDE.md, .cursor/    this brief and the agent wiring
.mcp.json, .cursor/mcp.json       the DroppyKit MCP server; absolute paths for this Mac
```

## Submitting

Your own build runs in Droppy only after you approve it under Settings, Store, Local
droplets, and Droppy asks again each time it opens; everyone else gets the droplet from
the Store, signed by Droppy after review.
When the droplet is done: replace the placeholder creator avatar (leave the icon: Jordy
designs it), fill in `creator` and `source` in `droplet.json`, write `CHANGELOG.md`, and run
`droppykit submit`. It leaves the icon out of the merge request; an idea for the icon goes in
the merge request's Icon concept section.
The Store is a repository (gitlab.com/droppyformac1/droplets, one folder per droplet):
`submit` forks it, copies this package into `droplets/<id>/`, pushes a branch and opens
the merge request; when a maintainer merges it, the pipeline builds, signs and publishes
it. `droppykit submit --print` shows the plan without doing it (needs `glab`, signed in).
Opening the merge request means accepting the Droplet developer terms at
https://getdroppy.app/droplet-developer-terms.

## Before `droppykit submit`

`droppykit new` filled these in so the package builds and validates from the
start. Every one is replaced before `droppykit submit`: the Store's checks
refuse a submission that still carries them, or review sends it back. Ask the
user for what only they can give (their name, their mark, what the droplet is
for) instead of inventing it. The icon is the one placeholder that stays (see
"The icon" below).

- `Assets/Creator.png`: their own square mark, 256px or more, not rounded. The
  scaffold's blue disc is refused byte for byte.
- `droplet.json`: `summary` (the scaffold's "One line about..." is refused),
  `description`, `category`, `creator.name` and `creator.url`.
- `id`: permanent from the first publish. Check now that it names the product
  (a droplet called Freelancy is `freelancy`); renaming later is impossible.
- `CHANGELOG.md`: the first entry says what the droplet does, in past-tense
  bullets under `## [1.0.0] - date`. Never only "First release.".
- `README.md`: the opening sentence and every section that says what goes in
  it, rewritten for the person deciding whether to install the droplet; leave
  out a section that does not apply. No developer checklist in it.
- The folder holds only what the Store takes: `droplet.json`, `Package.swift`,
  `Sources/`, `Assets/`, `CHANGELOG.md`, `README.md`. No `Tests/` folder or
  `.testTarget`, no scripts, no extra Markdown. `Package.swift` keeps one
  dynamic library, the `OpenchamberHarness` executable and DroppyKit as its
  only dependency, with no plugins, macros, binary targets, other executables
  or `unsafeFlags`. `droppykit submit` leaves the `.icon`, `.gitignore`,
  `Package.resolved`, `.build/`, shots and these agent files behind on its own.

## The icon

Full text: `/Users/josuegalre/projects/personal/droppykit/Sources/DroppyKit/Documentation.docc/Icons.md`.

- Jordy designs every Store droplet's icon. `Openchamber.icon` is a
  placeholder for the harness and the Playground: leave it exactly as
  `droppykit new` wrote it, and never generate, draw or replace an icon.
- `droppykit submit` leaves it out of the merge request. An idea for the icon
  goes in the merge request's Icon concept section: a sentence, a reference
  sketch or an SF Symbol to start from, never another company's logo.
- Glyphs and images inside the droplet's own UI are the developer's to make.

## Settings panes: what review sends back

Full rules: `/Users/josuegalre/projects/personal/droppykit/Sources/DroppyKit/Documentation.docc/SettingsPanes.md`,
"The rules, in one place".

- Root in `DropletSettingsPane`; its content is cards and
  `DropletSettingsSection`s straight inside, never a `VStack`.
- No `DropletSettingsDivider` in a native pane.
- Section headers are `settingsSectionHeader("Title")`, never
  `Text("Title").font(.headline)`.
- A boolean is a `DropletToggleRow`, never a two-option picker or a segmented
  control.
- A glyph (`icon:`) on every row of a card or on none.
- A subtitle is one short sentence.
- Buttons are `.bordered`, `.borderedProminent` or `.borderless`. The shelf's
  glass styles (`DroppyGlassButtonStyle`, `DroppyQuietButtonStyle`,
  `DroppyAccentButtonStyle`, `DroppyCircleButtonStyle`) never go on a settings
  page.
- Native `TextField` and `SecureField`, sentence case everywhere, and no page
  header of your own.

## Shelf widget height

`context.contentInsets` is 8 on every edge for a solo card under the notch
(DroppyKit 1.20.1), and 0 on every edge for a solo card on the island and the
camera island, in a grouped row and while the widget is wrapped around the
camera (1.21.0; the host clips those last two square). The declared height
includes the insets: `.fixed(150)` leaves 134 points for content alone under
the notch, and a grouped row hands the card the declared height less those 16
points, so its content keeps the same 134. Declare the content's height plus
the insets, and pad with `context.contentInsets` only, never a fixed number.
Check the shot of every size: a clipped last row is this.

## Good citizen

Full rules, with code for each: `/Users/josuegalre/projects/personal/droppykit/Sources/DroppyKit/Documentation.docc/GoodCitizen.md`.

- Work only while visible. Refresh in a `.task` on the widget's root view, or
  while `host.shelf.isExpanded` (`shelf-read`, observe `host.shelf.didChange`).
  `host.installState.state.activeWidgetIDs` lists your widgets on the user's
  Custom Shelf in Droppy after 16.0.1, and `host.installState.statePublisher`
  fires when one is placed or removed. Droppy 16.0.1 and earlier (Playground
  1.0.27 and earlier) report it empty, so never treat empty as "not placed".
- Never block the main actor: file, Accessibility and process I/O go on a
  dispatch queue of your own, never on Swift's cooperative threads either.
- Run a `Process` with a `terminationHandler`, output read while it runs, a
  timeout, and `kill(-pid, SIGTERM)` for the whole process group on timeout and
  in `deactivate()`. Never `waitUntilExit()` on the main actor.
- A keyboard event tap runs on its own thread and run loop, never the main run
  loop. A plain hotkey goes through `host.shortcuts` instead.
- Anything that takes over (a global shortcut over a system one, intercepting
  a key, a shelf takeover), costs battery (scanning, polling), pins the notch
  (a live activity that stays) or sends data starts off, and the user switches
  it on. No preset location or guessed account.
- Secrets (API keys, tokens, passwords, OTP seeds) go in the Keychain, never in
  `host.preferences`, which is plain `UserDefaults`.
- Read only your own container (`host.environment.containerDirectory`) and
  files the user hands you. Never another app's or droplet's data.
- English first: manifest, changelog, README and default strings in English,
  other languages as localizations chosen from
  `Bundle.main.preferredLocalizations`. Whole localizable sentences with
  placeholders, never concatenated fragments.
- Never create an `NSStatusItem`; conform to `MenuBarExtraProviding` with the
  `menu-bar` capability.
- Credit third-party code, artwork, sounds and data in the README's Credits
  section with their licence, keep their licence headers, and use nothing
  under the GPL or AGPL.
- No other company's logo or mark anywhere in the droplet, and no other
  company's name as the droplet's name.
