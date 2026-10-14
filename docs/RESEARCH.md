# Research notes: TrellisWM

Espalier is an independent reimplementation of the ideas behind
[TrellisWM](https://trelliswm.app/), "the fractal window manager for Mac" by Dan
Fessler (announced 13 October 2026). It's not affiliated with TrellisWM and
shares no code with it. Everything below comes from public descriptions of the
product.

These notes follow the evidence discipline from the REA "reverse engineer
anything" workflow. **Observations** are cited claims, **inferences** are labelled
with a confidence level, and **unknowns** are kept explicit instead of being
guessed into facts.

## How the evidence was gathered

- The build sandbox couldn't reach `trelliswm.app`, `x.com`, `taoofmac.com` or
  `trellisui.com`: the egress proxy refused them and DNS failed. So no REA
  static or runtime analysis could run against the site or the app binary, and
  REA itself wasn't installed. Its setup also needs an agent restart, which
  wasn't possible in this session.
- What remained were search-engine extracts of the TrellisWM homepage, the
  author's launch post, the Tao of Mac link post, and the source and docs of the
  author's open web library [`DanFessler/trellis`](https://github.com/DanFessler/trellis).
  That library's README says it was inspired by the window manager prototypes.
  It's licensed for non-commercial use only, so only its *documented concepts*
  were read. No code was copied.

## Observations

| # | Observation | Source |
|---|---|---|
| O1 | You can nest real Mac windows inside one another to any depth, then zoom to the part you need. | trelliswm.app (search extract) |
| O2 | Dragging a window onto another window's edge, or onto the screen's edge, docks it there. | trelliswm.app |
| O3 | Dragging the gap between two windows resizes both of them. | trelliswm.app |
| O4 | When zoomed out, a window too small to use shows its app's colour and icon. | trelliswm.app |
| O5 | A group too small to see becomes a single tile, lined with its splits. | trelliswm.app |
| O6 | Double-clicking a group's tile zooms into it. | trelliswm.app |
| O7 | Minimized windows come back to their original spot. | trelliswm.app |
| O8 | The arrangement is restored after TrellisWM restarts, and each display keeps its own layout. | trelliswm.app |
| O9 | Each display has 9 saved views, one keystroke each. | trelliswm.app |
| O10 | Every action is exposed as a URL, for use from Raycast, Alfred, Shortcuts, Stream Deck or a shell. Examples shown: `open trelliswm://arrange`, `open trelliswm://back`, `open trelliswm://zoom-out`. | trelliswm.app |
| O11 | Holding Option while pinching, or pinching on bare wallpaper, zooms the desktop. | trelliswm.app |
| O12 | Accessibility permission is required. Screen Recording is optional, and without it windows in motion are drawn as their app colour and icon. | trelliswm.app |
| O13 | Full-screen apps, other macOS desktops (Spaces), sheets and dialogs are left to macOS. | trelliswm.app |
| O14 | Requires macOS 14 Sonoma or later. | trelliswm.app |
| O15 | Free tier: docking, floating and zooming, with up to 5 docked windows per display. Pro tier: unlimited windows, tab groups, saved views and URL commands. There's also a Lifetime tier. | trelliswm.app |
| O16 | It's described as different from Mission Control: it arranges windows into a layout you work in, with spaces nested inside each other and a camera that moves between them. | trelliswm.app |
| O17 | In the author's web library, the "desktop" example uses `floating="stage"`, `navigation="free"` and a stage with id `desktop`. Floats live on the stage. Dropping near an empty stage's edges (within 64 px, or 28% of its size) docks beside the stage. Narrow bands (14%) along panel edges, the gaps between panels and the outer frame band all dock. A tab bar adds the dragged item as a tab. | `DanFessler/trellis` docs/floating.md, examples/desktop |
| O18 | In the web library, the camera frames a node or a contiguous run of siblings. Splits along the same axis are flattened into one level. Back and forward history, an overview toggle and saved framings are keyed by views rather than nodes. Opening or focusing something outside the current framing widens the framing to include it. | `DanFessler/trellis` docs/navigation.md, docs/zoomable-layouts.md |
| O19 | Tao of Mac's take: tab grouping and auto-tiling aren't new, but zooming to a subset of windows is the novel part. | taoofmac.com link post (search extract) |

## Inferences (and how Espalier implements them)

| # | Inference | Confidence | Competing explanation |
|---|---|---|---|
| I1 | The model is a tree. Leaves are tab groups of real windows, internal nodes are weighted row and column splits, and there's one **desktop** node where floating windows live. Docking at the screen edge with nothing docked yet puts the window beside the desktop rather than making it fill the screen. | High (O2, O17) | There might be no desktop node, with the first docked window filling the screen. |
| I2 | Zooming is an affine "camera" over the layout's unit square. A framed node fills the screen and everything outside it is moved off screen. Real windows can't be scaled, so windows outside the frame or too small to use are *parked* (moved almost entirely off screen) and drawn as overlay tiles instead. | High (O1, O4, O12) | Windows might be hidden through private CGS APIs instead. |
| I3 | Zoom animations are drawn by an overlay (wallpaper plus window proxies). Real windows jump straight to their final frames underneath it. | High (O12: "windows *in motion*") | — |
| I4 | `back` is camera history, and `zoom-out` steps out one level. | High (O10, O18) | — |
| I5 | `arrange` docks every floating window on the display into the layout. | Medium | It might only snap windows back into their slots. Espalier adds a separate `relayout` command for that. |
| I6 | Saved views store *which windows* were framed, not node ids, so they survive edits. | Medium-high (O18) | — |
| I7 | When you focus a parked window (Cmd-Tab, Dock click), the camera widens to show it. | Medium-high (O18) | — |
| I8 | Pinch zoom steps one level at a time once the pinch passes a threshold. Release doesn't snap continuously. | Low | TrellisWM may zoom continuously and snap on release, like the web library. |

## Unknowns

- U1: the full list of `trelliswm://` commands and their parameters. Only
  `arrange`, `back` and `zoom-out` are confirmed.
- U2: the default keyboard shortcuts, including the saved-view keystrokes.
- U3: how tab groups are drawn and switched in the real app.
- U4: whether floating windows scale with the desktop when the camera moves, or
  only get repositioned.
- U5: how windows are matched again after an *app* restarts (as opposed to a
  TrellisWM restart).
- U6: how windows are parked, and how that behaves when displays are arranged
  so that the parking corner is shared.
- U7: the trial length, the pricing, and how licensing is enforced. Espalier
  deliberately has no tiers or limits.

Espalier picks explicit, documented defaults for each of these. See the README.
