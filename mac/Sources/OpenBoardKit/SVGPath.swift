import CoreGraphics
import Foundation

/**
 The smallest SVG path parser that covers this catalog.

 Written rather than pulled in: the alternative was a dependency for ~150 lines of
 well-specified string walking, in a project whose whole build story is "no
 dependencies, builds with the CLT".
 */
public enum SVGPath {
    public static func parse(_ d: String) -> CGMutablePath {
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        /// Last cubic control point, for S's implied reflection.
        var lastControl: CGPoint?

        var scanner = Tokenizer(d)
        var command: Character = "M"

        while let token = scanner.peek() {
            if let letter = token.letter {
                command = letter
                scanner.advance()
            }
            // A repeated coordinate run continues the previous command, except that a
            // repeated M means L — a genuine quirk of the spec, and the catalog uses it.
            let effective = command
            switch effective {
            case "M", "m":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = effective == "m" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.move(to: current)
                start = current
                command = effective == "m" ? "l" : "L"
                lastControl = nil

            case "L", "l":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = effective == "l" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addLine(to: current)
                lastControl = nil

            case "H", "h":
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: effective == "h" ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil

            case "V", "v":
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: effective == "v" ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil

            case "C", "c":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let relative = effective == "c"
                let c1 = CGPoint(x: relative ? current.x + x1 : x1, y: relative ? current.y + y1 : y1)
                let c2 = CGPoint(x: relative ? current.x + x2 : x2, y: relative ? current.y + y2 : y2)
                let end = CGPoint(x: relative ? current.x + x : x, y: relative ? current.y + y : y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end

            case "S", "s":
                guard let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let relative = effective == "s"
                // The first control point mirrors the previous curve's second one.
                let c1 = lastControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let c2 = CGPoint(x: relative ? current.x + x2 : x2, y: relative ? current.y + y2 : y2)
                let end = CGPoint(x: relative ? current.x + x : x, y: relative ? current.y + y : y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end

            case "Q", "q":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let relative = effective == "q"
                let c = CGPoint(x: relative ? current.x + x1 : x1, y: relative ? current.y + y1 : y1)
                let end = CGPoint(x: relative ? current.x + x : x, y: relative ? current.y + y : y)
                path.addQuadCurve(to: end, control: c)
                lastControl = nil
                current = end

            case "A", "a":
                guard let rx = scanner.number(), let ry = scanner.number(),
                      let rotation = scanner.number(), let largeArc = scanner.number(),
                      let sweep = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let relative = effective == "a"
                let end = CGPoint(x: relative ? current.x + x : x, y: relative ? current.y + y : y)
                addArc(
                    to: path, from: current, to2: end,
                    rx: rx, ry: ry, rotation: rotation,
                    largeArc: largeArc != 0, sweep: sweep != 0
                )
                lastControl = nil
                current = end

            case "Z", "z":
                path.closeSubpath()
                current = start
                lastControl = nil

            default:
                // Unknown command: skip its numbers rather than spinning.
                while scanner.number() != nil {}
            }
        }
        return path
    }

    /// Endpoint-parameterised arc → centre parameterisation, per the SVG spec's
    /// implementation notes. Only used by the circles the generator rewrites as arcs.
    private static func addArc(
        to path: CGMutablePath,
        from p0: CGPoint, to2 p1: CGPoint,
        rx: Double, ry: Double, rotation: Double,
        largeArc: Bool, sweep: Bool
    ) {
        guard rx != 0, ry != 0 else {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let dx2 = (p0.x - p1.x) / 2, dy2 = (p0.y - p1.y) / 2
        let x1 = cos(phi) * dx2 + sin(phi) * dy2
        let y1 = -sin(phi) * dx2 + cos(phi) * dy2

        var rx = abs(rx), ry = abs(ry)
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }

        let sign: Double = largeArc == sweep ? -1 : 1
        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1)
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coefficient = denominator == 0 ? 0 : sign * (numerator / denominator).squareRoot()

        let cx1 = coefficient * rx * y1 / ry
        let cy1 = -coefficient * ry * x1 / rx
        let cx = cos(phi) * cx1 - sin(phi) * cy1 + (p0.x + p1.x) / 2
        let cy = sin(phi) * cx1 + cos(phi) * cy1 + (p0.y + p1.y) / 2

        let angle = { (ux: Double, uy: Double, vx: Double, vy: Double) -> Double in
            let dot = ux * vx + uy * vy
            let len = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
            guard len != 0 else { return 0 }
            let a = acos(max(-1, min(1, dot / len)))
            return (ux * vy - uy * vx) < 0 ? -a : a
        }

        let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        var transform = CGAffineTransform(translationX: cx, y: cy)
            .rotated(by: phi)
            .scaledBy(x: rx, y: ry)
        path.addArc(
            center: .zero, radius: 1,
            startAngle: theta, endAngle: theta + delta,
            clockwise: !sweep,
            transform: transform
        )
    }

    /// Walks numbers and command letters out of a path string.
    private struct Tokenizer {
        private let chars: [Character]
        private var index = 0

        init(_ text: String) { chars = Array(text) }

        struct Token { let letter: Character? }

        mutating func peek() -> Token? {
            skipSeparators()
            guard index < chars.count else { return nil }
            let c = chars[index]
            return Token(letter: c.isLetter ? c : nil)
        }

        mutating func advance() { index += 1 }

        private mutating func skipSeparators() {
            while index < chars.count, chars[index] == " " || chars[index] == "," || chars[index] == "\n"
                || chars[index] == "\t" || chars[index] == "\r" {
                index += 1
            }
        }

        mutating func number() -> Double? {
            skipSeparators()
            var text = ""
            if index < chars.count, chars[index] == "-" || chars[index] == "+" {
                text.append(chars[index])
                index += 1
            }
            var sawDigit = false
            while index < chars.count {
                let c = chars[index]
                if c.isNumber {
                    sawDigit = true
                    text.append(c)
                    index += 1
                } else if c == "." , !text.contains(".") {
                    text.append(c)
                    index += 1
                } else if c == "e" || c == "E" {
                    text.append(c)
                    index += 1
                    if index < chars.count, chars[index] == "-" || chars[index] == "+" {
                        text.append(chars[index])
                        index += 1
                    }
                } else {
                    break
                }
            }
            guard sawDigit else { return nil }
            return Double(text)
        }
    }
}
