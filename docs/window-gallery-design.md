# Window gallery and local window movement

## Navigation cleanup (0.4.2)

Keep the navy acrylic material, but give each destination one job: Windows opens
shared windows; Macs selects and manages discovered/saved connections; Settings
contains manual connection fields and updates. Remove the duplicate Screen View,
Desktop/Files tabs, session-only Recents, fake Open Any App action, promotional
sidebar tile and redundant device menu. Search, sorting, pagination, grid/list,
and the per-window Open/Hide menu remain functional controls.

Replace the improvised hardware drawing with a render of Apple's actual Mac
Studio model. Use neutral window symbols rather than guessing app logos from
document titles. Connection availability must distinguish discovery from a
working session; deduplicate saved and discovered copies of the same endpoint.
Verify the three destinations, device selection, search and preview/open behavior
on Windows before packaging. The earlier reference-layout notes below document
the previous revision, not requirements to retain redundant controls.

Runtime verification of 0.4.2 on ALIENWARE_A51: the Apple model render loads from
the executable with correct alpha; Macs lists the discovered real Mac and the
isolated local test host separately; Windows displays eight decoded fixture
previews. Name/host-order selection, title filtering, Enter-to-open without
disconnecting, and compact gallery pagination passed. Settings and the model
panel fit at 1464x934 and 1114x726 DIPs at 200% scaling. Disabled actions have a
muted fill. All 73 tests, including Media Foundation decode, pass; release build,
format and clippy with warnings denied pass. This revision does not change the
proxy renderer or movement loop. The earlier measured 200% physical/swapchain
equality stands; 100%, 150% and cross-monitor measurements remain unverified.

The Windows app is a window launcher: choose a Mac, inspect real previews, and
open only the windows needed on this PC. Closing a local window returns it to
the gallery without closing the Mac document. The Mac host chooses which apps
are shared; multiple chosen apps use one tiling budget and capture stream.

Palette: canvas #F6F8FC, surface #FFFFFF, sidebar #EAF0F8, ink #182438,
secondary #58677D, action #275DDB. Segoe UI regular is the Windows reading face;
semibold is reserved for window titles and actions. The Mac uses its native
system face with the same quiet blue accent and hierarchy.

    Transom        | Windows                       Search windows
    Your Macs      | Choose a window to open on this PC
    [Mac list]     | [actual preview] [actual preview]
    Connect        | Window title    Window title
    Disconnect     | Open window     Show window
    Manual…        |
    Updates        | Session status                 Previous / Next

The preview gallery is the focal point. Cards correspond to real remote windows,
not decorative metric panels. Settings remain in the sidebar; diagnostics on the
Mac move into a disclosure. Native keyboard-focusable buttons provide gallery
actions. Small windows paginate rather than cutting off cards.

Review against the brief: remove the old marketing headline and permanently
visible port form. Use actual decoded thumbnails, clear opening/empty/error
states, and native Windows caption controls. Preview thumbnails intentionally
scale only in the selector, as the existing Mac monitoring preview does; the
interactive stream retains exact physical pixel mapping.

Movement findings: a captured Mac title bar forwards drags to AX/WindowServer,
moving the source crop independently of its video frame. A local native caption
keeps movement on Windows. The old UI pump also stopped processing decoded
frames inside DefWindowProc's modal move loop. A timer must continue bounded
session work there. Moving without resizing must never send resize requests.

Native caption dimensions are excluded from the streamed client viewport.
AdjustWindowRectExForDpi converts desired client dimensions to outer dimensions;
GetClientRect remains authoritative for the swapchain. Only an active resize
may stretch the source; a normal move leaves both remote and client sizes alone.

Reference: https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-entersizemove

## Reference-directed dark acrylic redesign

The user supplied image-1.png as the exact visual target. It supersedes the light
palette above. Match its narrow 236 px sidebar, 156 px tall device panel, tab strip,
four-column 188 px preview cards, 16 px gutters, blue active/selection borders,
slate translucent surfaces and integrated window controls. Palette: ink #08131F,
glass #182333, blue #2869FF, secondary #B8C6DF, text #F3F6FC, online #54E577.
Segoe UI 14 px controls, 16 px headings and 24 px device/brand type. All figures
are DIPs in the shell; streaming remains physical pixels.

Use native Windows acrylic with premultiplied-alpha Direct2D rendering, rounded
geometry and DirectWrite text. The prior flat GDI treatment cannot match this
reference and is replaced. Live preview cards use actual decoded windows; real
connection state replaces the illustrative speed numbers. Connections, apps,
recents and settings remain usable, with a shared-display preview for Desktop.
The lower sidebar promotes sharing more apps rather than inventing a paid plan.

Review against brief: the target's color/material/proportions control the design.
Avoid substituting an unrelated generic dark theme or retaining the old layout.
Rendering must be compared visually with the supplied reference before completion.


### Windows rendering findings (2026-09-20)

GDI owner-drawn child controls left opaque rectangles and incorrect alpha on
an acrylic HWND. All buttons now keep their native HWND/input/accessibility
semantics but are painted on the parent Direct2D surface. A subclass validates
child WM_PAINT without issuing a second drawing pass. EDIT controls use layered
child surfaces with opaque alpha. Do not invalidate the parent from every child
paint: that creates a repaint loop which starves discovery and video messages.
Only changed state/input and the throttled preview refresh invalidate it.

Native button defaults can be altered by IsDialogMessage (default-button style).
Suppressing their independent GDI paint also prevents a white default-button
rectangle from replacing the blue primary action. Menus snapshot their data and
release the State borrow before TrackPopupMenu, because the modal timer continues
video processing during popup menus.

Runtime validation on ALIENWARE_A51 at 200% DPI: acrylic material, empty/connected
states, settings at 1464x934 and 1114x726 DIPs, eight decoded local-fixture previews,
search, opening/closing a native streamed window, and a bounded title-bar drag.
The fixture's control log recorded no resize request for that move. Real Mac
connection succeeds, but the host currently reports zero shared windows; these
populated-gallery tests use an explicitly labeled loopback fixture, not fabricated
Mac content. Real Mac multi-app capture and all-monitor DPI verification remain
separate checks; this UI pass does not claim 100%/150% or cross-monitor proof.
Final 0.4.1 runtime check: per-card Open and Hide menus passed with local HEVC
fixtures. The 200% DPI checkerboard probe reported:

    pixel-check: DPI=192 physical=400x240 swapchain=400x240 PASS

This checks the physical client/swapchain size on the current monitor. It does
not substitute for 100%, 150%, or cross-monitor measurements.
