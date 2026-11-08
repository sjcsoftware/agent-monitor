import CoreGraphics
import Foundation

/// Parses SVG path data (`M L H V C S Q T A Z`, absolute and relative) into a CGPath.
public enum SVGPath {
    public static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = Tokens(d)
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastQuad: CGPoint?
        var command: Character = "M"

        while let next = scanner.nextCommandOrNumber() {
            if case .command(let c) = next { command = c } else { scanner.pushBack() }
            let rel = command.isLowercase
            let base = rel ? current : .zero
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: base.x + x, y: base.y + y) }
            var resetControl = true, resetQuad = true
            switch command.uppercased() {
            case "M":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = pt(x, y); start = current
                path.move(to: current)
                command = rel ? "l" : "L" // subsequent pairs are implicit line-tos
            case "L":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = pt(x, y)
                path.addLine(to: current)
            case "H":
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: (rel ? current.x : 0) + x, y: current.y)
                path.addLine(to: current)
            case "V":
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: (rel ? current.y : 0) + y)
                path.addLine(to: current)
            case "C":
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x2 = scanner.number(),
                      let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let c2 = pt(x2, y2)
                current = pt(x, y)
                path.addCurve(to: current, control1: pt(x1, y1), control2: c2)
                lastControl = c2; resetControl = false
            case "S":
                guard let x2 = scanner.number(), let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = pt(x2, y2)
                current = pt(x, y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2; resetControl = false
            case "Q":
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let c = pt(x1, y1)
                current = pt(x, y)
                path.addQuadCurve(to: current, control: c)
                lastQuad = c; resetQuad = false
            case "T":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let c = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                current = pt(x, y)
                path.addQuadCurve(to: current, control: c)
                lastQuad = c; resetQuad = false
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(), let rot = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let end = pt(x, y)
                addArc(path, from: current, to: end, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                current = end
            case "Z":
                path.closeSubpath()
                current = start
            default:
                return path
            }
            if resetControl { lastControl = nil }
            if resetQuad { lastQuad = nil }
        }
        return path
    }

    /// SVG elliptical arc → cubic Béziers (SVG 1.1 implementation notes, F.6).
    private static func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                               rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || p0 == p1 {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4)
        func point(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi, y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
        }
        func derivative(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi, y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
        }
        var t = theta1
        for i in 0..<segments {
            let t2 = t + step
            let a = point(t), b = i == segments - 1 ? p1 : point(t2)
            let da = derivative(t), db = derivative(t2)
            path.addCurve(to: b, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                          control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
            t = t2
        }
    }

    private enum Token { case command(Character), number(CGFloat) }

    private struct Tokens {
        private let chars: [Character]
        private var i = 0
        private var lastStart = 0

        init(_ s: String) { chars = Array(s) }

        private mutating func skipSeparators() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i].isNewline || chars[i] == "\t" { i += 1 }
        }

        mutating func nextCommandOrNumber() -> Token? {
            skipSeparators()
            guard i < chars.count else { return nil }
            lastStart = i
            let c = chars[i]
            if c.isLetter && c != "e" && c != "E" {
                i += 1
                return .command(c)
            }
            return number().map { .number($0) }
        }

        mutating func pushBack() { i = lastStart }

        /// Arc flags may be written without separators (`a1 1 0 01…`).
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
            defer { i += 1 }
            return chars[i] == "1"
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = i
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
            var sawDot = false, sawDigit = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { sawDigit = true; i += 1 }
                else if c == "." && !sawDot { sawDot = true; i += 1 }
                else if (c == "e" || c == "E") && sawDigit {
                    i += 1
                    if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
                } else { break }
            }
            guard sawDigit, let v = Double(String(chars[begin..<i])) else {
                i = begin
                return nil
            }
            return CGFloat(v)
        }
    }
}
