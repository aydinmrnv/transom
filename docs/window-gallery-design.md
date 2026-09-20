# Window gallery and local window movement

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
