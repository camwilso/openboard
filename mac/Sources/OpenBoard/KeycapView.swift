import OpenBoardKit
import SwiftUI

/**
 Draws a keycap icon from the catalog's SVG path data.

 A small SVG path parser rather than an asset catalog, for two reasons: `actool` is
 an Xcode tool and this package builds with the Command Line Tools alone; and vectors
 tint and scale with the view, which a menu bar and a settings window at different
 sizes both need.

 Only the subset the catalog actually uses is implemented — M, L, H, V, C, S, Q, A, Z
 in both absolute and relative forms. An unsupported command is skipped rather than
 throwing: a slightly wrong glyph is a cosmetic problem, an app that will not draw
 its menu is not.
 */
struct KeycapIconView: View {
    let icon: KeycapIcon

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / icon.width, size.height / icon.height)
            let dx = (size.width - icon.width * scale) / 2
            let dy = (size.height - icon.height * scale) / 2
            var transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)

            for spec in icon.paths {
                let raw = SVGPath.parse(spec.d)
                let path = Path(raw.copy(using: [transform]) ?? raw)
                if spec.filled {
                    context.fill(path, with: .style(.foreground), style: FillStyle(eoFill: spec.evenOdd))
                }
                if spec.stroked {
                    context.stroke(
                        path,
                        with: .style(.foreground),
                        style: StrokeStyle(
                            lineWidth: spec.strokeWidth * scale,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
            }
        }
    }
}
