import SwiftUI

/** The Halloween look from the app design: a night-purple palette, Atkinson Hyperlegible Next type, and the moon, bats and cobweb header. */
enum Theme {
    static let background = hex(0x15101C)
    static let surface = hex(0x241B2F)
    static let line = hex(0x3D2F4F)
    static let bat = hex(0x5B4A72)
    static let muted = hex(0x8E80A3)
    static let soft = hex(0xD0C6E0)
    static let text = hex(0xF4EBFF)
    static let amber = hex(0xFDB022)
    static let moon = hex(0xFDE68A)
    static let crater = hex(0xF5D565)
    static let closed = hex(0xB42318)
    static let open = hex(0x067647)
    static let moving = hex(0x6B3FA0)

    enum Weight {
        case regular, semibold, bold
    }

    /** The design's typeface at a Dynamic Type size, so it still grows with the user's text-size setting. */
    static func font(_ style: Font.TextStyle, _ weight: Weight = .regular) -> Font {
        let name = switch weight {
        case .regular: "AtkinsonHyperlegibleNext-Regular"
        case .semibold: "AtkinsonHyperlegibleNext-SemiBold"
        case .bold: "AtkinsonHyperlegibleNext-Bold"
        }
        return .custom(name, size: baseSize(style), relativeTo: style)
    }

    private static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 24
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        default: 12
        }
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/** The design's home header: Export JSON on the left, the moon on the right opening Settings, with a cobweb and bats behind. */
struct ThemeHeader<ExportButton: View>: View {
    let openSettings: () -> Void
    @ViewBuilder let exportButton: () -> ExportButton

    var body: some View {
        ZStack(alignment: .topLeading) {
            Cobweb().stroke(Theme.line, lineWidth: 1.5).frame(width: 86, height: 82).accessibilityHidden(true)
            HStack(alignment: .center) {
                exportButton()
                Spacer(minLength: 12)
                ZStack {
                    Bat().fill(Theme.bat).frame(width: 22, height: 10).offset(x: -78, y: -24)
                    Bat().fill(Theme.bat).frame(width: 16, height: 7).offset(x: -114, y: 8)
                    Button(action: openSettings) { Moon().frame(width: 76, height: 76) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("settingsButton")
                }
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
    }
}

/** The full moon with craters and a bat crossing it, as drawn in the design. */
struct Moon: View {
    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 76
            ZStack {
                Circle().fill(Theme.moon).frame(width: 68 * scale, height: 68 * scale)
                Circle().fill(Theme.crater).frame(width: 10 * scale, height: 10 * scale).offset(x: -14 * scale, y: -10 * scale)
                Circle().fill(Theme.crater).frame(width: 14 * scale, height: 14 * scale).offset(x: 12 * scale, y: 12 * scale)
                Circle().fill(Theme.crater).frame(width: 6 * scale, height: 6 * scale).offset(x: 4 * scale, y: -16 * scale)
                Bat().fill(Theme.background).frame(width: 32 * scale, height: 14.4 * scale).offset(x: -6 * scale, y: 3 * scale)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true)
    }
}

/** The design's bat silhouette, from its 20 by 9 path. */
struct Bat: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 20, sy = rect.height / 9
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(0, 6))
        path.addQuadCurve(to: p(8, 4), control: p(4, 0))
        path.addQuadCurve(to: p(12, 4), control: p(10, 0))
        path.addQuadCurve(to: p(20, 6), control: p(16, 0))
        path.addQuadCurve(to: p(14, 8), control: p(16, 5))
        path.addQuadCurve(to: p(10, 9), control: p(12, 6))
        path.addQuadCurve(to: p(6, 8), control: p(8, 6))
        path.addQuadCurve(to: p(0, 6), control: p(4, 5))
        path.closeSubpath()
        return path
    }
}

/** The corner cobweb from the design's header, scaled from its 86 by 82 drawing. */
struct Cobweb: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 86, sy = rect.height / 82
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        for end in [p(86, 0), p(76, 40), p(40, 74), p(0, 82)] {
            path.move(to: p(0, 0))
            path.addLine(to: end)
        }
        path.move(to: p(26, 0))
        path.addQuadCurve(to: p(23, 12), control: p(22, 8))
        path.addQuadCurve(to: p(12, 21), control: p(18, 18))
        path.addQuadCurve(to: p(0, 25), control: p(6, 22))
        path.move(to: p(52, 0))
        path.addQuadCurve(to: p(46, 24), control: p(46, 15))
        path.addQuadCurve(to: p(24, 44), control: p(38, 38))
        path.addQuadCurve(to: p(0, 49), control: p(12, 47))
        path.move(to: p(78, 0))
        path.addQuadCurve(to: p(68, 36), control: p(70, 22))
        path.addQuadCurve(to: p(36, 67), control: p(58, 56))
        path.addQuadCurve(to: p(0, 74), control: p(18, 72))
        return path
    }
}
