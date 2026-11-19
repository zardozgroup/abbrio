public import AppKit
public import SnippetModel

/// The menu bar icon: a small sheet of text, with a badge when Espanso isn't expanding.
///
/// The images are templates, so the menu bar colors them for light, dark and highlighted states.
public enum MenuBarGlyph {
    enum Badge {
        case pause
        case secureInput
        case warning
    }

    /// The icon for a status, at menu bar size.
    public static func image(for status: EngineStatus) -> NSImage {
        let badge: Badge?
        switch status {
        case .running: badge = nil
        case .paused: badge = .pause
        case .secureInput: badge = .secureInput
        case .notRunning, .notInstalled: badge = .warning
        }
        let image = image(badge: badge, size: 18)
        image.accessibilityDescription = description(for: status)
        return image
    }

    static func description(for status: EngineStatus) -> String {
        switch status {
        case .running: return "Abbrio: Espanso is running"
        case .paused: return "Abbrio: expansions paused"
        case .secureInput: return "Abbrio: Secure Input is on"
        case .notRunning: return "Abbrio: Espanso isn't running"
        case .notInstalled: return "Abbrio: Espanso wasn't found"
        }
    }

    /// Draws the glyph on an 18-unit grid, scaled to `size` points.
    static func image(badge: Badge?, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: size / 18, y: size / 18)
            draw(badge: badge, in: context)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(badge: Badge?, in context: CGContext) {
        // With no service to expand anything, the sheet is drawn faint and the badge solid.
        let sheetAlpha: CGFloat = badge == .warning ? 0.45 : 1
        let ink = CGColor(gray: 0, alpha: 1)

        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setAlpha(sheetAlpha)
        context.setStrokeColor(ink)
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.addPath(CGPath(
            roundedRect: CGRect(x: 1.75, y: 3.25, width: 14.5, height: 11.5), cornerWidth: 3, cornerHeight: 3,
            transform: nil
        ))
        context.strokePath()
        // Three lines of text; the last one is short, like the end of a paragraph.
        for (y, length) in [(11.4, 7.5), (9.0, 9.0), (6.6, 5.5)] {
            context.move(to: CGPoint(x: 4.6, y: y))
            context.addLine(to: CGPoint(x: 4.6 + length, y: y))
        }
        context.strokePath()
        context.endTransparencyLayer()

        guard let badge else { return }
        let center = CGPoint(x: 13.6, y: 4.6)
        // A clear ring separates the badge from the sheet behind it.
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: center.x - 5.4, y: center.y - 5.4, width: 10.8, height: 10.8))
        context.setBlendMode(.normal)
        context.setFillColor(ink)
        context.fillEllipse(in: CGRect(x: center.x - 4.3, y: center.y - 4.3, width: 8.6, height: 8.6))

        // The mark is cut out of the badge.
        context.setBlendMode(.clear)
        switch badge {
        case .pause:
            for x in [center.x - 1.9, center.x + 0.7] {
                context.addPath(CGPath(
                    roundedRect: CGRect(x: x, y: center.y - 2.2, width: 1.2, height: 4.4),
                    cornerWidth: 0.4, cornerHeight: 0.4, transform: nil
                ))
            }
            context.fillPath()
        case .secureInput:
            for x in [center.x - 1.9, center.x + 1.9] {
                context.fillEllipse(in: CGRect(x: x - 1.1, y: center.y - 1.1, width: 2.2, height: 2.2))
            }
        case .warning:
            context.addPath(CGPath(
                roundedRect: CGRect(x: center.x - 0.65, y: center.y - 0.6, width: 1.3, height: 3.4),
                cornerWidth: 0.6, cornerHeight: 0.6, transform: nil
            ))
            context.fillPath()
            context.fillEllipse(in: CGRect(x: center.x - 0.75, y: center.y - 2.85, width: 1.5, height: 1.5))
        }
        context.setBlendMode(.normal)
    }
}
