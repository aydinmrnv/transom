//! Pure initial proxy-window sizing.
//!
//! Host rectangles are physical pixels. On a Retina host a perfectly ordinary
//! Mac window can therefore be larger than the Windows monitor's work area. An
//! exact 1:1 proxy is impossible until the host relayouts that window, so the
//! client chooses a visibly windowed target, asks the host for that size, and
//! uses the host's read-back as truth.

use crate::wire::Size;

/// When a host window cannot fit at 1:1, keep the initial proxy within this
/// fraction of the monitor work area. The spare border leaves an obvious grab
/// area and avoids making a fitted window indistinguishable from fullscreen.
const OVERSIZE_FIT_PERCENT: u64 = 85;

/// Choose the initial physical client size for a proxy.
///
/// Windows that already fit retain their exact host size. Oversized windows are
/// fitted uniformly into 85% of the work area, preserving aspect ratio. The
/// caller must request a host resize when the returned size differs; scaling is
/// only the short transition before the authoritative host read-back arrives.
pub fn initial_proxy_size(source: Size, work_area: Size) -> Size {
    let source = Size {
        w: source.w.max(1),
        h: source.h.max(1),
    };
    let work_area = Size {
        w: work_area.w.max(1),
        h: work_area.h.max(1),
    };

    if source.w <= work_area.w && source.h <= work_area.h {
        return source;
    }

    let bounds = Size {
        w: ((work_area.w as u64 * OVERSIZE_FIT_PERCENT) / 100).max(1) as u32,
        h: ((work_area.h as u64 * OVERSIZE_FIT_PERCENT) / 100).max(1) as u32,
    };

    // Compare aspect ratios without floating-point rounding. All intermediate
    // products use u64 so valid u32 wire sizes cannot overflow.
    if source.w as u64 * bounds.h as u64 > source.h as u64 * bounds.w as u64 {
        Size {
            w: bounds.w,
            h: ((source.h as u64 * bounds.w as u64) / source.w as u64).max(1) as u32,
        }
    } else {
        Size {
            w: ((source.w as u64 * bounds.h as u64) / source.h as u64).max(1) as u32,
            h: bounds.h,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fitting_window_keeps_exact_physical_size() {
        assert_eq!(
            initial_proxy_size(Size { w: 1280, h: 800 }, Size { w: 2560, h: 1400 }),
            Size { w: 1280, h: 800 }
        );
    }

    #[test]
    fn oversized_retina_window_stays_windowed_and_preserves_aspect() {
        assert_eq!(
            initial_proxy_size(Size { w: 3840, h: 1954 }, Size { w: 2560, h: 1400 }),
            Size { w: 2176, h: 1107 }
        );
    }

    #[test]
    fn tall_window_is_limited_by_height() {
        assert_eq!(
            initial_proxy_size(Size { w: 1200, h: 2400 }, Size { w: 1920, h: 1080 }),
            Size { w: 459, h: 918 }
        );
    }

    #[test]
    fn zero_dimensions_are_sanitized() {
        assert_eq!(
            initial_proxy_size(Size { w: 0, h: 0 }, Size { w: 0, h: 0 }),
            Size { w: 1, h: 1 }
        );
    }
}
