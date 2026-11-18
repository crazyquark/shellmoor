import UIKit
import SwiftTerm

struct Theme: Identifiable, Hashable {
    let id: String
    let name: String
    let background: UInt32
    let foreground: UInt32
    let cursor: UInt32
    let ansi: [UInt32]   // 16 colors

    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }

    var uiBackground: UIColor { UIColor(hex: background) }
    var uiForeground: UIColor { UIColor(hex: foreground) }
    var uiCursor: UIColor { UIColor(hex: cursor) }
    var isDark: Bool {
        let r = Double((background >> 16) & 0xff), g = Double((background >> 8) & 0xff), b = Double(background & 0xff)
        return (0.299 * r + 0.587 * g + 0.114 * b) < 128
    }
    var terminalColors: [SwiftTerm.Color] {
        ansi.map { SwiftTerm.Color(red8: UInt16(($0 >> 16) & 0xff), green8: UInt16(($0 >> 8) & 0xff), blue8: UInt16($0 & 0xff)) }
    }

    static let all: [Theme] = [
        Theme(id: "harbor", name: "Harbor", background: 0x0F1419, foreground: 0xD9DEE4, cursor: 0xF2A65A,
              ansi: [0x1C232B, 0xE06C6C, 0x8CC98A, 0xE8C46A, 0x6CA8E0, 0xC08CD9, 0x5FC4C0, 0xC5CCD4,
                     0x4A5562, 0xF08A8A, 0xA6DDA3, 0xF3D68A, 0x8DC0F0, 0xD5A8EA, 0x80D9D5, 0xF2F5F8]),
        Theme(id: "ember", name: "Ember", background: 0x1A1412, foreground: 0xE8DCCF, cursor: 0xFF8A3D,
              ansi: [0x2A211D, 0xD9614C, 0xA3B85C, 0xE0A646, 0x7A9EC2, 0xB880A8, 0x6FB3A2, 0xCFC2B4,
                     0x5C4F48, 0xEF7C66, 0xBCCF78, 0xF0BE66, 0x98B8D8, 0xCF9DC0, 0x8CCAB9, 0xF7EEE4]),
        Theme(id: "matrix", name: "Phosphor", background: 0x050A05, foreground: 0x7CF59A, cursor: 0x7CF59A,
              ansi: [0x0A140C, 0x4FBF6A, 0x7CF59A, 0xB4F5C4, 0x3E9E57, 0x62D17F, 0x9AF0B0, 0x9FD8AE,
                     0x1E3A25, 0x62D17F, 0xA6FFBC, 0xD2FFDC, 0x52B86C, 0x7CF59A, 0xBEFFCF, 0xE6FFEC]),
        Theme(id: "paper", name: "Paper", background: 0xFAF8F3, foreground: 0x2B2B2B, cursor: 0xC2410C,
              ansi: [0x2B2B2B, 0xB3261E, 0x2E7D32, 0x8A6D00, 0x1D5FB4, 0x8E3FA8, 0x00796B, 0xD0CCC2,
                     0x6B6B6B, 0xD13B32, 0x3C9A41, 0xA98600, 0x3578D0, 0xA855C4, 0x0E968A, 0xFFFFFF]),
        Theme(id: "dusk", name: "Dusk", background: 0x1E1B2E, foreground: 0xDCD7F0, cursor: 0xFFB86B,
              ansi: [0x2A2640, 0xF2777A, 0x99CC99, 0xFFCC66, 0x7DA6FF, 0xCC99CC, 0x66CCCC, 0xC8C3DD,
                     0x56506F, 0xFF8F92, 0xB2E0B2, 0xFFDB8A, 0x9DBBFF, 0xDDB2DD, 0x88DDDD, 0xF5F2FF]),
    ]
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
