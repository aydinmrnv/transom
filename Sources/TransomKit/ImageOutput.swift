import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A labelled rectangle to stroke over a captured frame, in **SCK pixel space**
/// (top-left origin, Y down) — the same space the frame pixels live in.
public struct OverlayRect: Sendable {
    public let rect: CGRect
    public let label: String
    public let color: CGColor

    public init(rect: CGRect, label: String, color: CGColor) {
        self.rect = rect
        self.label = label
        self.color = color
    }
}

public enum ImageOutput {

    /// Write a CGImage to disk as a PNG. Lossless — this is a diagnostic
    /// instrument and must not resample (I-1).
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard
            let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw ImageOutputError.destinationFailed(url)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageOutputError.writeFailed(url)
        }
    }

    /// Draw colored outlines (with labels) on top of a captured frame.
    ///
    /// The base image from SCK is upright (row 0 = top of screen). A bitmap
    /// `CGContext` is bottom-left origin, Y up, and drawing the image with no
    /// transform preserves that upright orientation. The incoming rects are in
    /// SCK/AX pixel space (top-left origin, Y **down**), so each rect's Y is
    /// converted to the context's bottom-left space exactly once here — the one
    /// conversion site, and NOT a global context flip (a global flip mirrors the
    /// whole frame, which is the upside-down bug this replaces).
    public static func overlay(base: CGImage, rects: [OverlayRect]) -> CGImage? {
        let width = base.width
        let height = base.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Upright: no transform.
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))

        let lineWidth = max(2.0, CGFloat(width) / 800.0)
        for r in rects {
            // Top-left/Y-down rect -> bottom-left/Y-up rect.
            let flipped = CGRect(
                x: r.rect.origin.x,
                y: CGFloat(height) - r.rect.origin.y - r.rect.size.height,
                width: r.rect.size.width,
                height: r.rect.size.height)
            ctx.setStrokeColor(r.color)
            ctx.setLineWidth(lineWidth)
            ctx.stroke(flipped)
            // Label baseline just inside the rect's top edge (top edge in screen
            // space = flipped.maxY in this context).
            drawLabel(
                r.label, atX: r.rect.origin.x + 3,
                baselineY: flipped.maxY - lineWidth - labelFontSize(width),
                color: r.color, in: ctx, scale: width)
        }
        return ctx.makeImage()
    }

    private static func labelFontSize(_ width: Int) -> CGFloat {
        max(11.0, CGFloat(width) / 130.0)
    }

    /// Draw an upright text label at a baseline in the context's (bottom-left,
    /// Y up) space. No local flip is needed because the context is not flipped.
    private static func drawLabel(
        _ text: String, atX x: CGFloat, baselineY: CGFloat, color: CGColor,
        in ctx: CGContext, scale: Int
    ) {
        let font = CTFontCreateWithName("Menlo" as CFString, labelFontSize(scale), nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: x, y: baselineY)
        CTLineDraw(line, ctx)
    }
}

public enum ImageOutputError: Error, CustomStringConvertible {
    case destinationFailed(URL)
    case writeFailed(URL)

    public var description: String {
        switch self {
        case .destinationFailed(let url): return "could not create PNG at \(url.path)"
        case .writeFailed(let url): return "could not finalize PNG at \(url.path)"
        }
    }
}
