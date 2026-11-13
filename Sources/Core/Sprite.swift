import Foundation

// Pixel-art agents. A fan-made sprite: a blocky creature with nub arms, two tall dot eyes and four stubby
// legs, drawn on a 14x14 grid. Everything here is pure so it can be tested; the app paints it in a Canvas.

public enum Look: String { case working, blocked, idle, done }

public func look(for s: Session) -> Look {
    if s.isFinished { return .done }
    switch s.state {
    case .working: return .working
    case .blocked: return .blocked
    case .idle: return .idle
    }
}

public struct RGB: Equatable { public var r, g, b: Double }

/// FNV-1a: stable across launches (Swift's hashValue is not).
public func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return h
}

public let spritePalette: [RGB] = [
    RGB(r: 0.851, g: 0.467, b: 0.341),   // clay
    RGB(r: 0.561, g: 0.682, b: 0.545),   // sage
    RGB(r: 0.486, g: 0.576, b: 0.722),   // slate
    RGB(r: 0.831, g: 0.663, b: 0.290),   // mustard
    RGB(r: 0.310, g: 0.639, b: 0.627),   // teal
    RGB(r: 0.627, g: 0.478, b: 0.722),   // plum
    RGB(r: 0.788, g: 0.482, b: 0.557),   // rose
    RGB(r: 0.761, g: 0.659, b: 0.541),   // sand
]

public struct SpriteStyle: Equatable {
    public var body: RGB
    public var variant: Int      // 0 plain, 1 antenna, 2 ears
}

public func spriteStyle(for sessionId: String) -> SpriteStyle {
    let h = stableHash(sessionId)
    return SpriteStyle(body: spritePalette[Int(h % UInt64(spritePalette.count))], variant: Int((h >> 16) % 3))
}

public enum PixelKind { case body, shade, eye, leg, spark, tip }

public struct Pixel: Equatable, Hashable {
    public var x: Int, y: Int
    public var kind: PixelKind
}

public let spriteGrid = 14

private let bodyRows = [
    "..BBBBBBBBBB..",
    "..BBBBBBBBBB..",
    "..BBEBBBBEBB..",
    "..BBEBBBBEBB..",
    "..BBBBBBBBBB..",
    "..BBBBBBBBBB..",
    "..SSSSSSSSSS..",
]
private let legRows = ["..L.L....L.L..", "..L.L....L.L.."]
private let top = 5   // rows of headroom: antenna/ears plus the hop

/// Vertical offset of the whole sprite for a hop (blocked, recently).
public func hopOffset(frame: Int) -> Int { [0, -2, -3, -2, 0, 0, 0, 0][((frame % 8) + 8) % 8] }

/// The pixels of one animation frame. `fresh` = blocked recently, so it hops.
public func spriteFrame(look: Look, frame f: Int, variant: Int, fresh: Bool = false) -> [Pixel] {
    let hop = look == .blocked && fresh ? hopOffset(frame: f) : 0
    let bob = look == .working && f % 2 == 1 ? -1 : 0
    var out: [Pixel] = []
    func put(_ x: Int, _ r: Int, _ k: PixelKind, legs: Bool = false) {
        let y = top + r + hop + (legs ? 0 : bob)
        guard x >= 0, x < spriteGrid, y >= 0, y < spriteGrid else { return }
        out.append(Pixel(x: x, y: y, kind: k))
    }
    for (r, row) in bodyRows.enumerated() {
        for (x, c) in row.enumerated() {
            switch c {
            case "B": put(x, r, .body)
            case "S": put(x, r, .shade)
            case "E":
                // Idle and done: eyes half closed (lower pixel only).
                if (look == .idle || look == .done) && r == 2 { put(x, r, .body) } else { put(x, r, .eye) }
            default: break
            }
        }
    }
    for (i, row) in legRows.enumerated() {
        for (x, c) in row.enumerated() where c == "L" { put(x, bodyRows.count + i, .leg, legs: true) }
    }
    switch variant {
    case 1: put(7, -1, .shade); put(7, -2, .tip)
    case 2: put(3, -1, .body); put(10, -1, .body)
    default: break
    }
    // Arms: two-pixel nubs at the sides.
    var leftArm = 4, rightArm = 4
    switch look {
    case .working:
        leftArm = f % 2 == 0 ? 3 : 4
        rightArm = f % 2 == 0 ? 4 : 2          // hammering
        if f % 2 == 1 { put(13, 0, .spark); put(11, -1, .spark) } else if f % 4 == 0 { put(13, 1, .spark) }
    case .blocked:
        rightArm = f % 4 < 2 ? 1 : 2           // waving
    case .idle, .done:
        break
    }
    put(0, leftArm, .body); put(1, leftArm, .body)
    put(12, rightArm, .body); put(13, rightArm, .body)
    if look == .blocked && rightArm < 4 { put(13, rightArm + 1, .body) }   // raised arm keeps a joint
    return out
}
