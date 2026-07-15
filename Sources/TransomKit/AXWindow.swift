import ApplicationServices
import CoreGraphics

/// One AX window and everything the probe reports about it.
///
/// `frame` is in **AX global space**: points, top-left origin, Y down (I-3).
public struct AXWindowInfo: Sendable {
    public let index: Int
    public let title: String
    public let frame: CGRect
    public let role: String
    public let subrole: String
    /// Whether AX reports `AXSize` as settable. This is the question OQ-2 cares
    /// about before we even try to write: does AX *claim* the window resizes?
    public let resizable: Bool
}

/// Thin, honest wrapper over `AXUIElement`. Every read returns what AX actually
/// says; every write is followed by a read-back (I-4). Nothing here reports a
/// requested value as though it were an actual one.
public struct AXWindow {
    public let element: AXUIElement
    public let index: Int

    public init(element: AXUIElement, index: Int) {
        self.element = element
        self.index = index
    }

    // MARK: - Enumeration

    /// The AX application element for a pid.
    public static func application(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    /// All windows AX reports for an application, in AX order.
    public static func windows(pid: pid_t) -> [AXWindow] {
        let app = application(pid: pid)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let array = value as? [AXUIElement] else {
            return []
        }
        return array.enumerated().map { AXWindow(element: $1, index: $0) }
    }

    // MARK: - Reads

    public func stringAttribute(_ attr: String) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    public var title: String { stringAttribute(kAXTitleAttribute) ?? "" }
    public var role: String { stringAttribute(kAXRoleAttribute) ?? "?" }
    public var subrole: String { stringAttribute(kAXSubroleAttribute) ?? "-" }

    /// Current position in AX global points, or nil if AX will not report it.
    public func position() -> CGPoint? {
        readAXValue(kAXPositionAttribute, type: .cgPoint) { raw in
            var p = CGPoint.zero
            return AXValueGetValue(raw, .cgPoint, &p) ? p : nil
        }
    }

    /// Current size in points, or nil if AX will not report it.
    public func size() -> CGSize? {
        readAXValue(kAXSizeAttribute, type: .cgSize) { raw in
            var s = CGSize.zero
            return AXValueGetValue(raw, .cgSize, &s) ? s : nil
        }
    }

    /// Current frame (position + size) in AX global points.
    public func frame() -> CGRect? {
        guard let p = position(), let s = size() else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Whether AX reports `AXSize` as settable.
    public func isResizable() -> Bool {
        var settable = DarwinBoolean(false)
        let err = AXUIElementIsAttributeSettable(
            element, kAXSizeAttribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    public func info() -> AXWindowInfo {
        AXWindowInfo(
            index: index,
            title: title,
            frame: frame() ?? .null,
            role: role,
            subrole: subrole,
            resizable: isResizable())
    }

    // MARK: - Writes (always followed by read-back — I-4)

    /// Set `AXPosition`. Returns the AX error verbatim; the caller must read back
    /// separately. This method does not lie about success.
    @discardableResult
    public func setPosition(_ point: CGPoint) -> AXError {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return .failure }
        return AXUIElementSetAttributeValue(
            element, kAXPositionAttribute as CFString, value)
    }

    /// Set `AXSize`. Returns the AX error verbatim.
    @discardableResult
    public func setSize(_ size: CGSize) -> AXError {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return .failure }
        return AXUIElementSetAttributeValue(
            element, kAXSizeAttribute as CFString, value)
    }

    // MARK: - Private

    private func readAXValue<T>(
        _ attr: String, type: AXValueType, unpack: (AXValue) -> T?
    ) -> T? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
            let value
        else { return nil }
        // A CFTypeRef holding an AXValue is bridged as AXValue via CFGetTypeID.
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        // swift-format-ignore: NeverForceUnwrap
        return unpack(value as! AXValue)
    }
}

/// The outcome of a `place`/geometry write: what we asked for, and what AX
/// actually gave back after the write. Reporting the delta is the entire point
/// of the `place` command (I-4, OQ-2).
public struct PlacementResult: Sendable {
    public let requestedPosition: CGPoint
    public let requestedSize: CGSize
    public let actualPosition: CGPoint?
    public let actualSize: CGSize?
    public let setPositionError: AXError
    public let setSizeError: AXError

    public var positionDelta: CGPoint? {
        guard let a = actualPosition else { return nil }
        return CGPoint(x: a.x - requestedPosition.x, y: a.y - requestedPosition.y)
    }

    public var sizeDelta: CGSize? {
        guard let a = actualSize else { return nil }
        return CGSize(
            width: a.width - requestedSize.width,
            height: a.height - requestedSize.height)
    }

    /// True only if AX accepted the write AND read-back equals the request
    /// exactly. Anything else is a delta the client must cope with.
    public var exact: Bool {
        positionDelta == CGPoint.zero && sizeDelta == CGSize.zero
    }
}

/// The outcome of a size-only AX write (issue #6 Phase 4): what we asked for and
/// what AX gave back. A resize keeps the window's position, so the client's
/// `RequestResize` carries only a size; we still read the position back because a
/// resize can shift the origin (some apps anchor growth at the bottom-left, so the
/// top-left moves), and the client needs the actual rect (I-4).
public struct ResizeReadback: Sendable {
    public let requestedSize: CGSize
    public let actualPosition: CGPoint?
    public let actualSize: CGSize?
    public let setSizeError: AXError

    public var sizeDelta: CGSize? {
        guard let a = actualSize else { return nil }
        return CGSize(
            width: a.width - requestedSize.width,
            height: a.height - requestedSize.height)
    }

    /// True only if AX accepted the write and read-back size equals the request.
    public var exact: Bool { sizeDelta == CGSize.zero }
}

extension AXWindow {
    /// Set `AXSize` only, then read position **and** size back, and report the
    /// delta (I-4). The resize roundtrip's non-negotiable steps 3–5
    /// (protocol.md §5): write, read back, report the *actual* size — clamped to an
    /// app minimum or not (OQ-2), never the requested one.
    public func resize(to size: CGSize) -> ResizeReadback {
        let err = setSize(size)
        let actualPos = self.position()
        let actualSize = self.size()
        return ResizeReadback(
            requestedSize: size,
            actualPosition: actualPos,
            actualSize: actualSize,
            setSizeError: err)
    }

    /// Write position + size, then read both back, and report the delta.
    ///
    /// AX ordering matters: some apps clamp position against the *current* size,
    /// so we set size first, then position, then read both. Even so, we only ever
    /// report the read-back values (I-4).
    public func place(position: CGPoint, size: CGSize) -> PlacementResult {
        let sizeErr = setSize(size)
        let posErr = setPosition(position)
        // Read back after both writes settle.
        let actualPos = self.position()
        let actualSize = self.size()
        return PlacementResult(
            requestedPosition: position,
            requestedSize: size,
            actualPosition: actualPos,
            actualSize: actualSize,
            setPositionError: posErr,
            setSizeError: sizeErr)
    }
}
