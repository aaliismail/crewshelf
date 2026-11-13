import CoreGraphics
import Foundation

// Where the shelf sits and which way its bubble opens. Pure geometry in AppKit screen coordinates (origin at the
// bottom-left of the main screen, y up), so it is tested without a window server.

public enum HSide: String { case left, right }
public enum VSide: String { case top, bottom }

/// A display as the shelf sees it: a stable id and its visible frame (no menu bar, no Dock).
public struct DisplayInfo: Equatable {
    public var id: String
    public var frame: CGRect
    public var isMain: Bool
    public init(id: String, frame: CGRect, isMain: Bool) { self.id = id; self.frame = frame; self.isMain = isMain }
}

/// The shelf's saved place: which display, which edges it hangs from, and how far from them. The shelf grows
/// away from those edges (toward the screen's center) as agents come and go, so it never runs off-screen.
public struct ShelfSpot: Equatable {
    public var display: String
    public var h: HSide
    public var v: VSide
    public var dx: Double          // distance from the `h` edge of the display's visible frame
    public var dy: Double          // distance from the `v` edge

    public init(display: String, h: HSide, v: VSide, dx: Double, dy: Double) {
        self.display = display; self.h = h; self.v = v; self.dx = dx; self.dy = dy
    }

    public static func corner(_ display: String, _ h: HSide = .right, _ v: VSide = .bottom) -> ShelfSpot {
        ShelfSpot(display: display, h: h, v: v, dx: shelfMargin, dy: shelfMargin)
    }

    /// The corner this spot sits in, if it is snapped into one (both distances at the margin).
    public var corner: (HSide, VSide)? { dx == shelfMargin && dy == shelfMargin ? (h, v) : nil }

    var dict: [String: Any] { ["display": display, "h": h.rawValue, "v": v.rawValue, "dx": dx, "dy": dy] }

    init?(dict: [String: Any]) {
        guard let d = dict["display"] as? String, let h = (dict["h"] as? String).flatMap(HSide.init),
              let v = (dict["v"] as? String).flatMap(VSide.init), let dx = dict["dx"] as? Double,
              let dy = dict["dy"] as? Double, dx.isFinite, dy.isFinite else { return nil }
        self.init(display: d, h: h, v: v, dx: dx, dy: dy)
    }
}

/// Gap between a snapped shelf and the screen edge.
public let shelfMargin: Double = 10
/// A drop this close to an edge snaps to it.
public let snapDistance: Double = 40

/// The display a frame belongs to: the one holding its center, else the one it overlaps most, else the main one.
public func display(for frame: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
    let c = CGPoint(x: frame.midX, y: frame.midY)
    if let d = displays.first(where: { $0.frame.contains(c) }) { return d }
    let best = displays.max { a, b in area(a.frame.intersection(frame)) < area(b.frame.intersection(frame)) }
    if let b = best, area(b.frame.intersection(frame)) > 0 { return b }
    return displays.first { $0.isMain } ?? displays.first
}

private func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

/// Where a shelf dropped at `frame` stays: the edges nearest its center, snapped to an edge or corner when it
/// lands within `snapDistance` of one, otherwise exactly where it was put (kept on screen).
public func dropSpot(_ frame: CGRect, displays: [DisplayInfo]) -> ShelfSpot? {
    guard let d = display(for: frame, in: displays) else { return nil }
    let vf = d.frame
    let h: HSide = frame.midX >= vf.midX ? .right : .left
    let v: VSide = frame.midY >= vf.midY ? .top : .bottom
    var dx = Double(h == .right ? vf.maxX - frame.maxX : frame.minX - vf.minX)
    var dy = Double(v == .top ? vf.maxY - frame.maxY : frame.minY - vf.minY)
    if dx < snapDistance { dx = shelfMargin }
    if dy < snapDistance { dy = shelfMargin }
    dx = min(dx, max(0, Double(vf.width - frame.width)))
    dy = min(dy, max(0, Double(vf.height - frame.height)))
    return ShelfSpot(display: d.id, h: h, v: v, dx: dx, dy: dy)
}

/// Where the shelf really sits for a saved spot: that spot while its display is connected, else (or with no spot)
/// the bottom-right corner of the main screen. The Corner menu ticks this one, not the saved spot.
public func effectiveSpot(_ spot: ShelfSpot?, displays: [DisplayInfo]) -> ShelfSpot? {
    guard let main = displays.first(where: { $0.isMain }) ?? displays.first else { return nil }
    if let sp = spot, displays.contains(where: { $0.id == sp.display }) { return sp }
    return .corner(main.id)
}

/// The shelf's frame for a saved spot. A spot on a display that is gone (or no spot at all) means the
/// bottom-right corner of the main screen. Always fully on screen.
public func shelfFrame(spot: ShelfSpot?, size: CGSize, displays: [DisplayInfo]) -> (frame: CGRect, spot: ShelfSpot)? {
    guard let s = effectiveSpot(spot, displays: displays) else { return nil }
    let vf = displays.first { $0.id == s.display }!.frame
    var x = s.h == .right ? vf.maxX - CGFloat(s.dx) - size.width : vf.minX + CGFloat(s.dx)
    var y = s.v == .top ? vf.maxY - CGFloat(s.dy) - size.height : vf.minY + CGFloat(s.dy)
    x = min(max(x, vf.minX), max(vf.minX, vf.maxX - size.width))
    y = min(max(y, vf.minY), max(vf.minY, vf.maxY - size.height))
    return (CGRect(x: x, y: y, width: size.width, height: size.height), s)
}

public struct BubblePlacement: Equatable {
    public var frame: CGRect
    public var below: Bool              // the bubble hangs under the shelf (shelf in the top half)
    public var tailX: CGFloat           // tail position from the bubble frame's left edge
    /// Height between the shelf and the screen edge on the bubble's side. A taller bubble is clamped onto the
    /// screen and would cover the shelf, so the app shrinks the bubble's scrolling part by `overflow`.
    public var room: CGFloat
    public var overflow: CGFloat { max(0, frame.height - room) }
}

/// How much to cut from a bubble's scrolling content so it fits `room`. `cut` is the cut the bubble was measured
/// with at `height`; the result is never below 0 or above `maxCut`. Converges in one step when the scrolling part
/// can absorb the change, so the app re-lays out only while the result changes.
public func bubbleCut(current cut: CGFloat, height: CGFloat, room: CGFloat, maxCut: CGFloat) -> CGFloat {
    min(max(0, cut + height - room), maxCut)
}

/// Bubbles open toward the screen's center: above a shelf in the bottom half, below one in the top half; lined
/// up with the shelf's outer edge and reaching inward. That side always has the most room. The tail points at
/// the character (`anchorX`). Clamped to the screen, so a bubble is never off-screen wherever the shelf sits; one
/// taller than the room on its side reports `overflow`, and the app makes it shorter so it never covers the shelf. `overlap` lets the transparent padding
/// of the two windows overlap so the visible gap stays small.
public func bubblePlacement(shelf: CGRect, anchorX: CGFloat, size: CGSize, screen: CGRect,
                            overlap: CGFloat = 10, tailInset: CGFloat = 26) -> BubblePlacement {
    let below = shelf.midY >= screen.midY
    var x: CGFloat
    if shelf.midX >= screen.midX {
        x = shelf.maxX - size.width                                     // reach left from the right edge
        if anchorX < x + tailInset { x = anchorX - tailInset }          // keep the character under the bubble
    } else {
        x = shelf.minX
        if anchorX > x + size.width - tailInset { x = anchorX + tailInset - size.width }
    }
    let room = below ? shelf.minY + overlap - screen.minY : screen.maxY - (shelf.maxY - overlap)
    var y = below ? shelf.minY + overlap - size.height : shelf.maxY - overlap
    x = min(max(x, screen.minX), max(screen.minX, screen.maxX - size.width))
    y = min(max(y, screen.minY), max(screen.minY, screen.maxY - size.height))
    let tail = min(max(anchorX - x, tailInset), max(tailInset, size.width - tailInset))
    return BubblePlacement(frame: CGRect(x: x, y: y, width: size.width, height: size.height), below: below, tailX: tail,
                           room: max(0, room))
}

/// Saved shelf spots, one per display, plus the display the shelf was last put on. A fallback to the main
/// screen is never saved, so the shelf goes back to its own display when that display returns.
public struct PlacementStore {
    public let defaults: UserDefaults
    public static let spotsKey = "shelfSpots"
    public static let displayKey = "shelfDisplay"

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public var spots: [String: ShelfSpot] {
        let raw = defaults.dictionary(forKey: PlacementStore.spotsKey) ?? [:]
        var out: [String: ShelfSpot] = [:]
        for (k, v) in raw { if let d = v as? [String: Any], let s = ShelfSpot(dict: d) { out[k] = s } }
        return out
    }

    /// The spot to restore: the one on the display the shelf was last put on.
    public var current: ShelfSpot? {
        guard let id = defaults.string(forKey: PlacementStore.displayKey) else { return nil }
        return spots[id]
    }

    public func save(_ s: ShelfSpot) {
        var raw = defaults.dictionary(forKey: PlacementStore.spotsKey) ?? [:]
        raw[s.display] = s.dict
        defaults.set(raw, forKey: PlacementStore.spotsKey)
        defaults.set(s.display, forKey: PlacementStore.displayKey)
    }
}
