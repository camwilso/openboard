import AppKit
import OpenBoardKit

/**
 The six LED dots, drawn as an image.

 **Why not just SwiftUI.** `MenuBarExtra`'s `label:` only reliably renders `Text` and
 `Image`. An `HStack` of `Circle` shapes builds and runs and produces a status item
 that is present, sized and clickable — and completely invisible. That is exactly how
 it failed: the popover opened from a blank patch of menu bar.

 So the dots are drawn with Core Graphics into an `NSImage` and handed over as an
 `Image`, which is the one shape the menu bar is guaranteed to draw.

 `isTemplate` is deliberately **false**. A template image is recolored to match the
 menu bar's appearance, which would throw away the only information here — these are
 hardware colors and the whole point is that the dot matches the key.
 */
enum StatusItemImage {
    private static let dot: CGFloat = 6
    private static let gap: CGFloat = 3
    private static let height: CGFloat = 16

    /// One dot per slot, in board order.
    static func make(slots: [SlotView], usable: Bool) -> NSImage {
        guard usable else { return warning() }

        let count = max(slots.count, 1)
        let width = CGFloat(count) * dot + CGFloat(count - 1) * gap

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            let y = (height - dot) / 2

            for (index, slot) in slots.enumerated() {
                let x = CGFloat(index) * (dot + gap)
                let rect = CGRect(x: x, y: y, width: dot, height: dot)

                if let appearance = slot.appearance, appearance.effect != .off {
                    // Brightness reads as alpha: at 6pt a dim color and a bright one
                    // are otherwise indistinguishable.
                    let alpha = 0.45 + 0.55 * appearance.brightness
                    context.setFillColor(
                        red: appearance.color.red,
                        green: appearance.color.green,
                        blue: appearance.color.blue,
                        alpha: alpha
                    )
                    context.fillEllipse(in: rect)
                } else {
                    // A free or ended slot is an outline, not a filled dot — "nothing
                    // here" has to look different from "deliberately dark".
                    context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
                    context.setLineWidth(1)
                    context.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /**
     The pad is unusable, so every dot would be a claim about hardware that is not
     listening. One plain dot instead.

     It used to be a red warning glyph, and red was the wrong word. The overwhelmingly
     common reason the pad is unreachable is that it went to sleep — it did so forty
     times in one day here, twenty-one of those for longer than fifteen seconds — and
     none of that is a fault. An alarm colour for the normal resting state of the
     hardware is how a colour stops meaning anything, and red is the one this app can
     least afford to spend: it means a turn failed.

     A single dot where the six were, so the board reads as collapsed to one indicator
     rather than replaced by a different kind of icon — but larger than one of them. Six
     dots at 6pt read as a row because there are six; one alone at that size reads as a
     speck of dust on the menu bar.

     ## Template, so it is white where white is right

     `isTemplate` is true here and false for the session dots, which look like a
     contradiction and are not. The session dots carry hardware colours and must never
     be recoloured. This one carries no colour information at all, so it should be the
     menu bar's own foreground — white on a dark menu bar, dark on a light one. Filling
     it with literal white would make it invisible for anyone in light appearance.
     */
    private static func warning() -> NSImage {
        // Larger than a session dot, and deliberately so. Six dots at 6pt read as a row
        // because there are six of them; one alone at that size reads as a speck of
        // dust on the menu bar. This is roughly the weight the old warning glyph had.
        let size: CGFloat = 10
        let image = NSImage(size: NSSize(width: size, height: height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            let rect = CGRect(x: 0, y: (height - size) / 2, width: size, height: size)
            // Any opaque colour: a template image is a mask, and only its alpha is kept.
            context.setFillColor(NSColor.black.cgColor)
            context.fillEllipse(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "OpenBoard — pad unreachable"
        return image
    }
}
