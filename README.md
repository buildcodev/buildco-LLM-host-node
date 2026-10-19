# Espalier

Tab groups for any windows on macOS, built to sit alongside a window snapper such as
Grid. Put Outlook and Teams in one group, snap the group to
half the screen with Grid, and click between them like browser tabs.

Espalier doesn't lay windows out. Grid (or you) decides where a window goes; Espalier
keeps the group together wherever its shown window ends up.

This branch (`espalier-tabs`) is a cut-down rework of Espalier the fractal window
manager, which is on the `espalier-window-manager` branch.

## How it works

- **Making tabs:** drag a window by its title bar onto the top of another window (its
  title bar or just below, or its tab strip) and hold it there for a moment. An outline
  in your accent colour shows the area; let go inside it and they share a strip of tabs
  above the window. A quick drag across another window doesn't make tabs.
- **Switching:** click a tab (the selected one is a raised capsule tinted with its app's
  colour). Only the chosen tab is shown; the others wait just off
  the screen's corner and take the same place when chosen. Cmd-Tab or a Dock click on
  a waiting tab switches to it too.
- **Moving a group:** whatever moves the shown window moves the group. Snap it with
  Grid (F5 / F6, ⌃⌥ arrows, maximize) and the strip follows; dragging the window by
  its title bar moves the group too. When the strip wouldn't fit above (Grid's halves
  start at the top of the screen), the window gives up the top 36 points so the strip
  and window together fill the half.
- **Rearranging:** drag a tab along the strip to reorder it. Drag it off the strip to
  take it out of the group, or onto another window's title bar to move it there.
- **Wide apps:** some apps won't get narrower than half the screen (Outlook needs
  1368 points of a 2624-point display). When two windows or groups are snapped side
  by side and one of them needs more than half, the line between them moves to give
  it the room and the other side narrows. When both need more than they can share,
  the width is split in proportion to what each needs. Espalier learns each app's
  minimum the first time it refuses to shrink, and remembers it. Switching a group
  to a narrower tab moves the line back.
- **Closing tabs:** each tab has an ×, like a browser tab. Clicking it closes that
  window (a waiting tab is shown first, so a "save changes?" question can be seen);
  ⌥-click quits the window's app instead. Close or minimize the shown tab any other way
  and the next one takes its place. A minimized tab comes back as the shown tab.
- **Restarts:** groups are saved and found again after Espalier or the apps restart.
  Quitting Espalier puts every waiting tab back on screen.

## Install

Requires macOS 14 Sonoma or later. Build it with Swift 5.9+ (Xcode 15 or later, or
just the Command Line Tools):

```sh
scripts/bundle.sh            # builds dist/Espalier.app
cp -R dist/Espalier.app /Applications/
open /Applications/Espalier.app
```

Espalier asks for **Accessibility** permission in System Settings → Privacy &
Security. It's required: it's how one app moves another app's windows.

The app is signed ad hoc, so macOS treats each rebuild as a new app. After rebuilding
you may need to switch Accessibility off and on again for Espalier. Set
`CODESIGN_IDENTITY` to a Developer ID identity to avoid this.

Don't run it alongside another tool that hides windows in tabs or lays them out
(TrellisWM, for example): the menu bar item warns when TrellisWM is running.

## Using it with Grid

Grid's F5 / F6 (left and right half) work on the focused window, which in a group is
the shown tab, so they move the whole group. On a Mac keyboard F5 and F6 are media
keys unless "Use F1, F2, etc. keys as standard function keys" is on (System Settings
→ Keyboard), so press them with fn.

Espalier's own shortcuts stay clear of Grid's ⌃⌥ letters and arrows.

| To | Do this |
|---|---|
| Make tabs | Drag a window onto the top of another (or its strip), hold, let go |
| Switch tab | Click it, or ⌃⌥] / ⌃⌥[ for the next / previous tab |
| Reorder | Drag a tab along the strip |
| Take a tab out | Drag it off the strip, or choose Take Window Out of Its Group |

### URL commands

```sh
open espalier://next-tab       # also: previous-tab
open espalier://tab/2          # show the focused group's second tab
open espalier://ungroup        # take the focused window out of its group
open espalier://ungroup-all
```

### Settings

`~/Library/Application Support/Espalier/config.json` is created on first launch.
Any key can be left out. Choose **Reload Settings** from the menu bar item after
editing it.

```json
{
  "hotkeys": { "next-tab": "ctrl+alt+]", "tab/1": "ctrl+alt+1", "previous-tab": "" },
  "stripHeight": 36,
  "maxTabWidth": 280,
  "holdDelay": 0.35,
  "dropZoneHeight": 80,
  "widenSides": true,
  "excludedBundleIDs": ["com.apple.systempreferences"]
}
```

If `config.json` was written by the window-manager version of Espalier, it's moved
to `config.window-manager.json` and a fresh one is written. Groups are saved in
`tabs.json`, along with the minimum width learned for each app.

## Design

```
Sources/EspalierCore   platform-independent model (pure Swift, unit-tested on Linux and macOS)
  Tabs.swift           tab groups: adding, removing, showing, reordering, restoring after a restart
  Placement.swift      where a strip and its tabs go; side-by-side detection and the line between halves
  Commands.swift       URL commands and shortcut parsing
Sources/Espalier       the macOS app (AppKit, Accessibility, Carbon hot keys)
  TabManager.swift     keeps groups together, follows Grid, drag-to-tab, widening sides
  StripWindow.swift    the tab strip panel and the drop outline
  WindowTracker.swift  per-app AXObservers plus a periodic reconcile
  EventTap.swift       watches mouse drags (never blocks on another app)
```

A strip is a capsule of the system's glass (Liquid Glass on macOS 26, a translucent blur
before that) in a non-activating panel ordered directly above its group's shown window, so
windows in front of the group cover the strip too, and clicking a tab never takes
focus from your apps. Waiting tabs are moved off screen with a one-point sliver left,
the way macOS tiling tools hide windows.

## Limitations

- Snapped halves are recognised by their shape: nearly full height, roughly half the
  width, against the left edge or from the middle to the right edge. Quarters and
  thirds don't widen.
- When a group is snapped to the bottom half, its strip sits above the window and
  overlaps the top half by its height.
- Windows on other Spaces aren't seen until you visit that Space, so a group whose
  windows are on another Space when Espalier starts loses them.
- Full-screen windows are left to macOS.

## Development

```sh
swift test                                                                 # model tests (Swift Testing)
scripts/test.sh                                                            # same, and also works with only the Command Line Tools
docker run --rm -v "$PWD":/src -w /src swift:6.1-noble swift test        # same, on Linux
```

CI runs the model's tests on Linux, and builds, tests and bundles the app on macOS.
