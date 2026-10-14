# Espalier

A fractal window manager for macOS. Nest windows inside each other as deep as you
like, then zoom the camera to the part you need.

Espalier is an independent, open reimplementation of the ideas in
[TrellisWM](https://trelliswm.app/). It's not affiliated with TrellisWM and shares
no code with it. [docs/RESEARCH.md](docs/RESEARCH.md) lists what's known about the
original (with sources), what was inferred, and what's still unknown.

## How it works

- **Desktop:** every display starts as one desktop, where windows float as they
  normally would.
- **Docking:** drag a window onto an edge and it docks there, splitting the space.
  The edge can belong to another window, a group, the desktop, or the screen.
  Dock beside a window that's already docked and you get a nested layout, to any
  depth.
- **Tabs:** drop a window on another docked window's title bar and they share one
  slot as tabs. A tab strip appears above them, and clicking a tab switches to it.
- **Resizing:** drag the gap between two docked windows to resize both. Resizing a
  docked window by its own border moves the neighbouring gaps to follow it.
- **Zooming:** the camera can frame the whole layout, one window, or any group or
  run of neighbours in between. Everything outside the frame is moved off screen,
  and it all keeps running.
- **Tiles:** a window too small to use at the current zoom is drawn as its app's
  colour and icon. A nested group that's too small even for icons becomes one tile
  lined with its splits. Double-click any tile to zoom to it.
- **Revealing:** focusing a window that's off camera (Cmd-Tab, a Dock click, a new
  window) widens the camera until the window is visible and big enough to use.
- **Minimizing:** minimized and hidden windows keep their slot and come back to it.
- **Saved views:** each display has nine. Layouts are saved per display and restored
  after Espalier restarts.
- **Commands:** every command is available as a URL, so Raycast, Alfred, Shortcuts,
  a Stream Deck or a shell script can drive Espalier.

Zoom transitions are animated. If you grant Screen Recording, moving windows show
their real contents; without it they're drawn as their app's colour and icon.

## Install

Requires macOS 14 Sonoma or later. Build it with Swift 5.9+ (Xcode 15 or later):

```sh
scripts/bundle.sh            # builds dist/Espalier.app (add --universal for Intel + Apple silicon)
cp -R dist/Espalier.app /Applications/
open /Applications/Espalier.app
```

When it starts, Espalier asks for **Accessibility** permission in System Settings →
Privacy & Security. This permission is required, since it's how one app moves
another app's windows. **Screen Recording** is optional and can be turned on from
the menu bar icon.

The app is signed ad hoc, so macOS treats each rebuild as a new app. After
rebuilding you may need to switch Accessibility off and on again for Espalier.
Set `CODESIGN_IDENTITY` to a Developer ID identity to avoid this.

## Using it

| To | Do this |
|---|---|
| Dock a window | Drag it onto the edge of another window, the desktop, or the screen. A blue preview shows where it will go. |
| Make tabs | Drag it onto the title bar of a docked window. |
| Keep a window floating | Hold Shift when you let go. |
| Float a docked window | Drag it onto the desktop, or press ⌃⌥F (which also docks a floating window beside the desktop). |
| Resize | Drag the gap between two windows. |
| Zoom in / out a level | ⌃⌥↓ / ⌃⌥↑, or pinch over bare desktop, or hold ⌥ and pinch anywhere. |
| Fill the screen with a window | ⌃⌥↩. Press it again to go back. |
| Zoom to a tile | Double-click it. |
| See everything | ⌃⌥O. Press it again to go back. |
| Back / forward | ⌃⌥← / ⌃⌥→ |
| Saved views | ⌃⌥1 – ⌃⌥9 to go to a view, ⌃⌥⇧1 – ⌃⌥⇧9 to save one. |
| Dock every floating window | ⌃⌥A |
| Move focus | ⌃⌥⌘ + arrow |
| Switch tabs | ⌃⌥] / ⌃⌥[ |

### URL commands

Each command is `espalier://<name>`:

```sh
open espalier://arrange       # dock every floating window
open espalier://relayout      # put every window back in its slot
open espalier://back          # previous camera position (also: forward)
open espalier://zoom-out      # one level out (also: zoom-in, overview, maximize)
open espalier://view/3        # go to saved view 3 (save-view/3 saves it)
open espalier://focus/left    # move focus (left, right, top/up, bottom/down)
open espalier://dock/right    # dock the focused window against the right edge of the screen
open espalier://toggle-float  # dock or float the focused window
open espalier://next-tab      # also: previous-tab
```

### Settings

`~/Library/Application Support/Espalier/config.json` is created on first launch.
You can open it from the menu bar icon, and any key can be left out. Choose
**Reload Settings** after editing it.

```json
{
  "metrics": { "gap": 8, "margin": 8, "usableSize": { "width": 240, "height": 150 } },
  "hotkeys": { "zoom-out": "cmd+alt+up", "back": "" },
  "docking": true,
  "keepFloatingModifier": "shift",
  "pinchModifier": "alt",
  "animationDuration": 0.28,
  "excludedBundleIDs": ["com.apple.systempreferences"]
}
```

`hotkeys` maps command names to shortcuts and overrides the defaults above. An
empty string turns a shortcut off. Layouts are saved next to the settings in
`state.json`.

## Design

```
Sources/EspalierCore   platform-independent layout engine (pure Swift, unit-tested on Linux and macOS)
  Layout.swift         the tree: splits, tab groups and the desktop; docking, tabs, removal, normalisation
  Camera.swift         world/screen mapping, framings, zooming levels, history and saved views
  Presentation.swift   what the screen shows for a camera: window frames, parked windows, tiles, tab strips, gaps
  DisplayState.swift   one display's state, drop targets, resizing, arrange, reveal
  Commands.swift       URL commands and shortcut parsing
Sources/Espalier       the macOS app (AppKit, Accessibility, Carbon hot keys, ScreenCaptureKit)
  WindowManager.swift  applies presentations to real windows and routes input
  WindowTracker.swift  per-app AXObservers plus a periodic reconcile
  EventTap.swift       mouse and pinch input
  Overlay.swift        icon tiles and tab strips (below windows); zoom animation and drop preview (above them)
```

The layout is a tree in a unit square. Splits are weighted rows or columns, the
leaves are tab groups, and one leaf is the desktop. The camera is a rect in that
square that gets mapped onto the screen. Framing a node makes it fill the display.
Windows can't be scaled, so any window outside the camera, or smaller than it can
usefully be, is *parked*: moved off screen with a one-pixel sliver left, the way
other macOS tiling managers hide windows. An overlay tile is drawn in its place.

The camera remembers *which windows* it framed rather than which node. That keeps
history and saved views working as the tree is edited.

## Limitations

- Full-screen windows, sheets, dialogs and other Spaces are left to macOS. Windows
  on another Space give up their room while you're away and get it back when you
  return.
- Parked windows can still be reached with Cmd-Tab or the Dock. Focusing one
  zooms the camera to it.
- Pinch zooming steps one level at a time instead of zooming continuously.
- When a display is disconnected, its windows float on the displays they move to.
  Its layout comes back when the display does.

## Development

```sh
swift test                                                                 # layout engine tests
docker run --rm -v "$PWD":/src -w /src swift:6.1-noble swift test        # same, on Linux
```

CI runs the engine's tests on Linux, and builds, tests and bundles the app on macOS.
