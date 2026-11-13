import ServiceManagement
import SwiftUI

enum Palette {
    static let bg = Color(red: 0.039, green: 0.039, blue: 0.043)        // zinc-950
    static let raised = Color(red: 0.094, green: 0.094, blue: 0.106)    // zinc-900
    static let line = Color(red: 0.153, green: 0.153, blue: 0.165)      // zinc-800
    static let shelf = Color(red: 0.200, green: 0.200, blue: 0.216)     // zinc-700ish
    static let text = Color(red: 0.894, green: 0.894, blue: 0.906)      // zinc-200
    static let dim = Color(red: 0.631, green: 0.631, blue: 0.667)       // zinc-400
    static let mute = Color(red: 0.443, green: 0.443, blue: 0.478)      // zinc-500
    static let faint = Color(red: 0.322, green: 0.322, blue: 0.357)     // zinc-600
    static let accent = Color(red: 0.976, green: 0.451, blue: 0.086)    // orange-500
    static let spark = Color(red: 0.992, green: 0.729, blue: 0.290)     // amber
    static let eye = Color(red: 0.067, green: 0.067, blue: 0.075)
    static let ok = Color(red: 0.290, green: 0.871, blue: 0.502)        // green-400
}

func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }

extension RGB {
    func color(_ k: Double = 1) -> Color { Color(red: r * k, green: g * k, blue: b * k) }
}

let pixelSize: CGFloat = 3
let slotWidth: CGFloat = 46
let slotSpacing: CGFloat = 4
let shelfPad: CGFloat = 10
let bubbleWidth: CGFloat = 300
let chevronWidth: CGFloat = 12

/// Frames of named views in their window (y down from the top), reported up to the window's root view.
struct FramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, b in b }
    }
}

extension View {
    func probe(_ name: String) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: FramesKey.self, value: [name: g.frame(in: .global)]) })
    }
}

// MARK: sprite

struct SpriteCanvas: View {
    let s: Session
    let frame: Int
    let fresh: Bool
    var px: CGFloat = pixelSize

    var body: some View {
        let lk = look(for: s)
        let style = spriteStyle(for: s.sessionId)
        let grey = RGB(r: 0.30, g: 0.30, b: 0.33)
        let base = lk == .done ? grey : style.body
        let pixels = spriteFrame(look: lk, frame: frame, variant: style.variant, fresh: fresh)
        Canvas(rendersAsynchronously: false) { ctx, _ in
            for p in pixels {
                let c: Color
                switch p.kind {
                case .body: c = base.color()
                case .shade, .leg: c = base.color(0.72)
                case .eye: c = lk == .done ? grey.color(0.55) : Palette.eye
                case .spark: c = Palette.spark
                case .tip: c = lk == .done ? grey.color() : Palette.accent
                }
                ctx.fill(Path(CGRect(x: CGFloat(p.x) * px, y: CGFloat(p.y) * px, width: px, height: px)), with: .color(c))
            }
        }
        .frame(width: CGFloat(spriteGrid) * px, height: CGFloat(spriteGrid) * px)
    }
}

let dimBadgeHelp = "Waiting in its terminal. Crewshelf can't answer this one (no plugin)."

/// A pixel check on a 5x4 grid, drawn in 2 px squares.
private let checkPixels: [(Int, Int)] = [(4, 0), (3, 1), (0, 2), (2, 2), (1, 3)]

/// Above the head: an orange "!" when it has a request you can answer here and its bubble is closed, a dim "!"
/// when it waits somewhere Crewshelf can't answer (no plugin, or handed to the terminal), three bouncing pixel dots
/// while it works, a pixel check after it finishes (until clicked or it works again). Nothing otherwise.
struct Badge: View {
    let s: Session
    let frame: Int
    var bang = false         // an answerable request whose bubble is not on screen
    var dim = false          // waiting, but not answerable in Crewshelf
    var fresh = false
    var check = false        // finished a turn, not clicked yet
    var body: some View {
        if dim && look(for: s) == .blocked {
            VStack {
                Spacer(minLength: 0)
                Text("!").font(mono(10, .heavy)).foregroundColor(Palette.mute)
                    .frame(width: 14, height: 13)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Palette.raised))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.line, lineWidth: 1))
            }
            .help(dimBadgeHelp)
        } else if bang && look(for: s) == .blocked {
            let pop: CGFloat = fresh ? [1.0, 1.15, 1.25, 1.15, 1.0, 1.0, 1.0, 1.0][frame % 8] : 1
            VStack {
                Spacer(minLength: 0)
                Text("!").font(mono(10, .heavy)).foregroundColor(Palette.eye)
                    .frame(width: 14, height: 13)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Palette.accent))
                    .scaleEffect(pop, anchor: .bottom)
            }
        } else if look(for: s) == .working {
            Canvas { ctx, size in
                let d: CGFloat = 4
                let gap: CGFloat = 3
                let w = d * 3 + gap * 2 + 8
                let pill = CGRect(x: (size.width - w) / 2, y: size.height - d - 10, width: w, height: d + 8)
                ctx.fill(Path(roundedRect: pill, cornerRadius: 3), with: .color(Palette.raised))
                ctx.stroke(Path(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3), with: .color(Palette.line), lineWidth: 1)
                for i in 0..<3 {
                    let active = (frame % 4) == i
                    let up: CGFloat = active ? 2 : 0
                    let r = CGRect(x: pill.minX + 4 + CGFloat(i) * (d + gap), y: pill.minY + 4 - up, width: d, height: d)
                    ctx.fill(Path(r), with: .color(active ? Palette.accent : Palette.spark.opacity(0.6)))
                }
            }
        } else if check {
            Canvas { ctx, size in
                let p: CGFloat = 2
                let w: CGFloat = 26, h: CGFloat = 12
                let pill = CGRect(x: (size.width - w) / 2, y: size.height - h - 2, width: w, height: h)
                ctx.fill(Path(roundedRect: pill, cornerRadius: 3), with: .color(Palette.raised))
                ctx.stroke(Path(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3), with: .color(Palette.line), lineWidth: 1)
                let ox = pill.midX - 5 * p / 2, oy = pill.midY - 4 * p / 2
                for (x, y) in checkPixels {
                    ctx.fill(Path(CGRect(x: ox + CGFloat(x) * p, y: oy + CGFloat(y) * p, width: p, height: p)), with: .color(Palette.ok))
                }
            }
        } else {
            Color.clear
        }
    }
}

/// Animation frames: 4 a second, on boundaries shared by every character, so they stay in step.
let frameEpoch = Date(timeIntervalSinceReferenceDate: 0)
func animationFrame(_ d: Date) -> Int { Int(d.timeIntervalSinceReferenceDate * 4) }

/// A character animates 4 times a second only while it moves (working, or waiting on you) and the shelf is on
/// screen; idle and finished ones are still and are not redrawn at all. A moving one is drawn by Core Animation
/// (`MovingFace`): no SwiftUI update and no layout per frame, which keeps an animating shelf cheap.
struct Character: View {
    @ObservedObject var model: CrewshelfModel
    let s: Session

    var body: some View {
        let lk = look(for: s)
        CharacterFrame(model: model, s: s, frame: animationFrame(model.now),
                       moving: model.onScreen && (lk == .working || lk == .blocked))
    }
}

/// What a character's badge and sprite show, minus the frame.
struct FaceKey: Hashable {
    var sessionId: String
    var look: Look
    var fresh, bang, dim, check: Bool
}

/// The badge over the head and the sprite: the only part of a character that changes from frame to frame.
struct Face: View {
    let s: Session
    let frame: Int
    let key: FaceKey
    var body: some View {
        VStack(spacing: 0) {
            Badge(s: s, frame: frame, bang: key.bang, dim: key.dim, fresh: key.fresh, check: key.check)
                .frame(height: 18)
            SpriteCanvas(s: s, frame: frame, fresh: key.fresh)
        }
        .frame(width: slotWidth)
    }
}

let faceSize = CGSize(width: slotWidth, height: 18 + CGFloat(spriteGrid) * pixelSize)

/// The frames in which a face can look different. Two frames with the same phase draw the same pixels, so the
/// face is only redrawn when its phase changes (a waiting character that no longer hops: twice a second).
func facePhase(_ key: FaceKey, frame f: Int) -> Int {
    let m = ((f % 8) + 8) % 8
    switch key.look {
    case .working: return m % 4                         // bob and arms every frame, the dots on a 4-frame cycle
    case .blocked: return key.fresh ? m : (m % 4 < 2 ? 0 : 2)   // hop and pop on 8 frames, else the wave
    case .idle, .done: return 0
    }
}

/// The 4 Hz clock every moving face shares, on the same frame boundaries the still ones use, so they stay in
/// step. It runs only while some face is subscribed.
@MainActor
final class FaceClock {
    static let shared = FaceClock()
    private var faces = NSHashTable<FaceView>.weakObjects()
    private var timer: Timer?

    func add(_ v: FaceView) {
        faces.add(v)
        guard timer == nil else { return }
        let next = Date(timeIntervalSinceReferenceDate: (floor(Date().timeIntervalSinceReferenceDate * 4) + 1) / 4)
        let t = Timer(fire: next, interval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.01
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func remove(_ v: FaceView) {
        faces.remove(v)
        if faces.allObjects.isEmpty { timer?.invalidate(); timer = nil }
    }

    func redrawAll() { for v in faces.allObjects { v.redraw() } }

    private func tick() {
        let f = animationFrame(Date().addingTimeInterval(0.01))      // a tick that fires a hair early is still its frame
        for v in faces.allObjects { v.show(frame: f) }
        if faces.allObjects.isEmpty { timer?.invalidate(); timer = nil }
    }
}

/// A moving face as a layer: each phase is rendered once, by the same SwiftUI views a still face uses (so it looks
/// exactly the same), and the clock swaps the layer's contents. Clicks and hovers go through to the SwiftUI views
/// around it.
@MainActor
final class FaceView: NSView {
    var session: Session?
    var key: FaceKey?
    private var shownPhase: Int?
    private var current: CGImage?
    private static var cache: [String: CGImage] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.contents = current; layer?.contentsScale = scale }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// `--ctl snapshot` and `record` capture at their own scale (README images are made at 2x on any display).
    static var captureScale: CGFloat? { didSet { FaceClock.shared.redrawAll() } }
    var scale: CGFloat { Self.captureScale ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { FaceClock.shared.add(self); redraw() } else { FaceClock.shared.remove(self) }
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); redraw() }

    func set(_ s: Session, _ k: FaceKey) {
        let changed = k != key || s.sessionId != session?.sessionId
        session = s
        key = k
        if changed { redraw() }
    }

    func redraw() { shownPhase = nil; show(frame: animationFrame(Date())) }

    func show(frame f: Int) {
        guard let s = session, let k = key else { return }
        let phase = facePhase(k, frame: f)
        guard phase != shownPhase else { return }
        shownPhase = phase
        current = Self.image(s, k, phase: phase, scale: scale)
        layer?.contents = current
        layer?.contentsScale = scale
    }

    static func image(_ s: Session, _ k: FaceKey, phase: Int, scale: CGFloat) -> CGImage? {
        let style = spriteStyle(for: s.sessionId)
        let id = "\(style.body.r),\(style.body.g),\(style.body.b),\(style.variant)|\(k.look)|\(k.fresh)\(k.bang)\(k.dim)\(k.check)|\(phase)@\(scale)"
        if let img = cache[id] { return img }
        if cache.count > 400 { cache.removeAll() }
        let r = ImageRenderer(content: Face(s: s, frame: phase, key: k).environment(\.colorScheme, .dark))
        r.scale = scale
        r.proposedSize = ProposedViewSize(faceSize)
        let img = r.cgImage
        cache[id] = img
        return img
    }
}

struct MovingFace: NSViewRepresentable {
    let s: Session
    let key: FaceKey
    func makeNSView(context: Context) -> FaceView { FaceView(frame: NSRect(origin: .zero, size: faceSize)) }
    func updateNSView(_ v: FaceView, context: Context) { v.set(s, key) }
}

struct CharacterFrame: View {
    @ObservedObject var model: CrewshelfModel
    let s: Session
    let frame: Int
    var moving = false

    var body: some View {
        let key = FaceKey(sessionId: s.sessionId, look: look(for: s), fresh: model.isFresh(s),
                          bang: BubbleQueue.answerable(s) && model.bubbles.open?.sessionId != s.sessionId,
                          dim: BubbleQueue.waitsElsewhere(s), check: model.bubbles.hasCheck(s.sessionId))
        VStack(spacing: 0) {
            if moving {
                MovingFace(s: s, key: key)
                    .frame(width: faceSize.width, height: faceSize.height)
                    .help(key.dim && key.look == .blocked ? dimBadgeHelp : "")   // the layer takes no events
            } else {
                Face(s: s, frame: frame, key: key)
            }
            Rectangle().fill(model.bubbles.open?.sessionId == s.sessionId ? Palette.accent : Color.clear)
                .frame(width: 22, height: 2).padding(.top, 1)
        }
        .frame(width: slotWidth)
        .contentShape(Rectangle())
        .probe("char:" + s.sessionId)
        .onTapGesture { model.tap(s, clickCount: CrewshelfPanel.lastClickCount) }
        .onHover { inside in
            if inside { model.now = Date(); model.hoverId = s.sessionId } else if model.hoverId == s.sessionId { model.hoverId = nil }
        }
    }
}

struct Shelf: View {
    @ObservedObject var model: CrewshelfModel

    var tooltip: String? {
        guard let id = model.hoverId, let s = model.shelf.first(where: { $0.sessionId == id }) else { return nil }
        let dur = s.since.map { formatDuration(model.now.timeIntervalSince($0)) } ?? ""
        let muted = model.calm.muted.contains(s.sessionId) ? " · muted" : ""
        return "\(s.name) · \(s.project) · \(lookLabel(look(for: s))) \(dur)\(muted)"
    }

    var tip: some View {
        Text(tooltip ?? " ").font(mono(10)).foregroundColor(Palette.dim).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Palette.bg))
            .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
            .opacity(tooltip == nil ? 0 : 1)
            .frame(maxWidth: 420, alignment: model.shelfSide.h == .right ? .trailing : .leading)
            .allowsHitTesting(false)
    }

    /// The shelf grows away from the screen edge it hangs from, and its tooltip sits on the side facing the center.
    var body: some View {
        VStack(alignment: model.shelfSide.h == .right ? .trailing : .leading, spacing: 3) {
            if model.shelfSide.v == .bottom { tip }
            plank
            if model.shelfSide.v == .top { tip }
        }
    }

    var plank: some View {
            Group {
                HStack(alignment: .bottom, spacing: slotSpacing) {
                    let shown = model.collapsed ? [] : model.shownShelf
                    if model.shelf.isEmpty {
                        Text("no agents").font(mono(10)).foregroundColor(Palette.faint).frame(height: 44)
                            .allowsHitTesting(false)
                    } else if !model.collapsed && shown.isEmpty {
                        Text("\(model.shelf.count) idle").font(mono(10)).foregroundColor(Palette.faint).frame(height: 44)
                            .allowsHitTesting(false)
                    }
                    if model.collapsed {
                        if let s = model.collapsedFace { Character(model: model, s: s) }
                        let n = model.bubbles.needsYouCount(model.shelf)
                        if n > 0 {
                            Button { model.setCollapsed(false) } label: {
                                Text("\(n)").font(mono(10, .heavy)).foregroundColor(Palette.eye)
                                    .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 15)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(Palette.accent))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help("\(n) agent\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") you. Click to expand")
                            .padding(.bottom, 16)
                            .probe("count")
                        }
                        let e = model.bubbles.elsewhereCount(model.shelf)
                        if e > 0 {
                            Button { model.setCollapsed(false) } label: {
                                Text("\(e)").font(mono(10, .heavy)).foregroundColor(Palette.mute)
                                    .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 15)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(Palette.raised))
                                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.line, lineWidth: 1))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("\(e) agent\(e == 1 ? "" : "s") wait\(e == 1 ? "s" : "") in \(e == 1 ? "its" : "their") terminal, where Crewshelf can't answer. Click to expand")
                            .padding(.bottom, 16)
                            .probe("count-elsewhere")
                        }
                    } else {
                        ForEach(shown, id: \.sessionId) { s in Character(model: model, s: s) }
                    }
                    if model.testControlBadge {
                        Text("test").font(mono(9.5, .semibold)).foregroundColor(Palette.dim)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.mute, lineWidth: 1))
                            .padding(.bottom, 16)
                            .help("Test control is on (CREWSHELF_TEST_CONTROL=1): Crewshelf --ctl can approve requests in this instance")
                            .probe("test-control")
                    }
                    Chevron(collapsed: model.collapsed) { model.setCollapsed(!model.collapsed) }
                }
                .padding(.horizontal, shelfPad)
                .padding(.bottom, 5)
                .background(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [Palette.shelf, Palette.line], startPoint: .top, endPoint: .bottom))
                        .frame(height: 5)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                        .allowsHitTesting(false)      // a press on the plank reaches ShelfGrip behind it
                }
                .background(ShelfGrip(model: model))
                .probe("shelf")
            }
    }
}

/// Everything on the shelf that is not a character or a button: drag it to move the shelf, double-click it to
/// collapse or expand. It sits behind the characters, so a press on a character never reaches it.
struct ShelfGrip: View {
    @ObservedObject var model: CrewshelfModel
    @State private var moving = false
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.setCollapsed(!model.collapsed) }
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { v in
                    if !moving { moving = true; model.onDrag?(.began, v.startLocation) }
                    model.onDrag?(.moved, v.location)
                }
                .onEnded { v in
                    moving = false
                    model.onDrag?(.ended, v.location)
                })
            .help("Drag to move. Double-click to collapse. Right-click for alerts and Quit.")
    }
}

/// A pixel chevron at the shelf's end. Points right to collapse, left to expand.
struct Chevron: View {
    let collapsed: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Canvas { ctx, size in
                let p: CGFloat = 2
                let rows: [Int] = [0, 1, 2, 1, 0]
                let ox = (size.width - 3 * p) / 2, oy = (size.height - 5 * p) / 2
                for (y, x) in rows.enumerated() {
                    let col = collapsed ? 2 - x : x
                    ctx.fill(Path(CGRect(x: ox + CGFloat(col) * p, y: oy + CGFloat(y) * p, width: p, height: p)),
                             with: .color(hover ? Palette.accent : Palette.mute))
                }
            }
            .frame(width: chevronWidth, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Expand the shelf" : "Collapse the shelf: no bubbles open on their own")
        .onHover { hover = $0 }
        .padding(.bottom, 8)
    }
}

// MARK: bubbles

struct SmallButton: View {
    let title: String
    var color: Color = Palette.dim
    var filled = false               // the one primary action: solid orange, dark text
    var tip: String = ""
    var onHint: (String?) -> Void = { _ in }
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(mono(10.5, filled ? .semibold : .medium)).foregroundColor(filled ? Palette.eye : color)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(filled ? Palette.accent.opacity(hover ? 0.85 : 1) : hover ? Palette.line : Palette.raised))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(filled ? Palette.accent : Palette.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .probe("button:" + title)
        .help(tip)
        .onHover { h in hover = h; onHint(h && !tip.isEmpty ? tip : nil) }
    }
}

struct ChoiceRow: View {
    let label: String
    let detail: String?
    let selected: Bool
    let multi: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(multi ? (selected ? "[x]" : "[ ]") : (selected ? "(•)" : "( )")).font(mono(10))
                    .foregroundColor(selected ? Palette.accent : Palette.faint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(mono(10.5, selected ? .medium : .regular))
                        .foregroundColor(selected ? Palette.accent : Palette.text)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if let d = detail, !d.isEmpty {
                        Text(d).font(.system(size: 9.5)).foregroundColor(Palette.mute).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Palette.line : Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected || hover ? Palette.accent.opacity(0.6) : Palette.line, lineWidth: 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }.probe("option:" + label)
    }
}

let previewMaxHeight: CGFloat = 190
let previewMinHeight: CGFloat = 52
let questionsMaxHeight: CGFloat = 300
let questionsMinHeight: CGFloat = 70
/// The most a bubble's scrolling part can be shortened to fit beside the shelf.
let maxBubbleCut: CGFloat = questionsMaxHeight - questionsMinHeight

/// Lines of a preview body, wrapped at about this many characters inside a bubble.
private let wrapColumns = 44

func estimatedHeight(_ text: String, lineHeight: CGFloat = 13) -> CGFloat {
    let rows = text.components(separatedBy: "\n").reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / Double(wrapColumns)))) }
    return CGFloat(rows) * lineHeight + 12
}

/// Full tool input: a command, or a +/- diff for edits. Every line is there; long input scrolls inside the bubble.
/// One row per line (lazy), so a long input stays cheap to draw.
struct PreviewBody: View {
    let preview: PermissionPreview
    var cut: CGFloat = 0             // taken off the 190 pt cap so the bubble fits beside the shelf
    var body: some View {
        let lines = preview.body.components(separatedBy: "\n")
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { i in row(lines[i]) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .frame(height: min(max(previewMinHeight, previewMaxHeight - cut), estimatedHeight(preview.body)))
        .background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .leading) { Rectangle().fill(Palette.accent).frame(width: 2) }
    }

    @ViewBuilder func row(_ line: String) -> some View {
        if preview.style != .diff {
            text(line, Palette.text)
        } else {
            // A fixed marker column, so a wrapped + or - line keeps its marker's indent and never reads as context.
            let (mark, rest, color): (String, String, Color) =
                line.hasPrefix("+ ") ? ("+", String(line.dropFirst(2)), Palette.text)
                : line.hasPrefix("- ") ? ("-", String(line.dropFirst(2)), Palette.mute)
                : (" ", line, Palette.faint)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(mark + " ").font(mono(10)).foregroundColor(mark == "+" ? Palette.accent : Palette.mute).fixedSize()
                text(rest, color)
            }
        }
    }

    func text(_ line: String, _ color: Color) -> some View {
        Text(line.isEmpty ? " " : line).font(mono(10)).foregroundColor(color).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

let openTip = "Go to this agent's terminal tab"

/// What a state is called on screen: "blocked" is the code's word, "waiting" the user's.
func lookLabel(_ l: Look) -> String { l == .blocked ? "waiting" : l.rawValue }
let endTip = "Stop this agent. Its chat is saved and can be reopened"
let hideTip = "Hide this tab from Crewshelf until its state changes"

struct Bubble: View {
    @ObservedObject var model: CrewshelfModel
    let item: BubbleItem
    let s: Session
    let tail: BubbleTail?            // points at the character; on top when the bubble hangs below the shelf

    var detail: Detail? { model.details[s.sessionId] }
    var showsPrompt: Bool { item.kind == .prompt || (item.kind == .manual && s.state == .blocked) }
    var request: PendingRequest? { model.pending[s.sessionId]?.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if item.kind == .finished { finished }
            else if showsPrompt, let req = request { RequestView(model: model, s: s, req: req).id(req.id) }
            else if showsPrompt { waiting }
            else { steps }
            actions
        }
        .padding(.horizontal, 11)
        .padding(.top, tail?.top == true ? 17 : 10).padding(.bottom, tail.map { $0.top ? 10 : 17 } ?? 10)
        .frame(width: bubbleWidth, alignment: .leading)
        .background(BubbleShape(tail: tail).fill(Palette.bg))
        .overlay(BubbleShape(tail: tail).stroke(showsPrompt ? Palette.accent.opacity(0.55) : Palette.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
        .onHover { model.bubbleHover = $0 }
        .onDisappear { model.bubbleHover = false }     // closed under the pointer: no exit event comes
    }

    var header: some View {
        HStack(alignment: .center, spacing: 7) {
            SpriteCanvas(s: s, frame: 0, fresh: false, px: 1.5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(s.name).font(.system(size: 11.5, weight: .semibold)).foregroundColor(Palette.text).lineLimit(1)
                    Spacer(minLength: 4)
                    status
                }
                (Text("\(s.project) · \(s.kind == .background ? "bg \(s.shortId ?? "")" : s.headless ? "headless" : "tab")")
                    .foregroundColor(Palette.faint)
                 + Text(s.hooked ? "" : " · no plugin").foregroundColor(Palette.dim))
                    .font(mono(9.5)).lineLimit(1)
            }
            Button { model.dismiss(item) } label: {
                Text("×").font(mono(12)).foregroundColor(Palette.mute).frame(width: 14, height: 14).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Dismiss").probe("button:×")
        }
    }

    /// "waiting 21s" while it waits on you, the countdown in the same place in its last minute, "done", or the state.
    @ViewBuilder var status: some View {
        let since = s.since.map { formatDuration(model.now.timeIntervalSince($0)) } ?? ""
        if item.kind == .finished {
            Text("done").font(mono(9.5)).foregroundColor(Palette.mute)
        } else if showsPrompt, let req = request, req.deadline.timeIntervalSince(model.now) < 60 {
            Text("\(max(0, Int(req.deadline.timeIntervalSince(model.now))))s left").font(mono(9.5, .medium)).foregroundColor(Palette.accent)
                .help(req.hasTerminal ? "Then Crewshelf lets go without approving; the prompt stays in the terminal."
                                      : "Then Crewshelf lets go without approving, and the call is denied.")
        } else {
            Text("\(showsPrompt ? "waiting" : lookLabel(look(for: s))) \(since)").font(mono(9.5))
                .foregroundColor(showsPrompt ? Palette.accent : Palette.mute)
        }
    }

    var finished: some View {
        Text(item.summary ?? "Finished its turn.").font(mono(10.5)).foregroundColor(Palette.text).lineLimit(3)
            .truncationMode(.tail).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    @ViewBuilder var waiting: some View {
        if let needs = s.needs, !needs.isEmpty {
            HStack(spacing: 0) {
                Rectangle().fill(Palette.accent).frame(width: 2)
                Text(needs).font(mono(10.5)).foregroundColor(Palette.text).lineLimit(14)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                Spacer(minLength: 0)
            }
            .background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 5))
            if let r = s.suggestedReply {
                Text("suggested: \(r)").font(mono(9.5)).foregroundColor(Palette.mute).textSelection(.enabled)
            }
        } else {
            Text("Waiting for \(s.waitingFor ?? "you").").font(mono(10.5)).foregroundColor(Palette.dim)
            if let st = detail?.transcript?.steps.last(where: { $0.pending }) { stepRow(st) }
        }
        if let n = detail?.note {
            Text(n).font(.system(size: 10)).foregroundColor(Palette.mute).fixedSize(horizontal: false, vertical: true)
        }
    }

    func stepRow(_ st: Step) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(st.name).font(mono(10, .medium)).foregroundColor(st.pending ? Palette.accent : Palette.dim)
                .frame(width: 52, alignment: .leading).lineLimit(1)
            (Text(st.isError ? "× " : "").foregroundColor(Palette.accent) + Text(st.summary).foregroundColor(st.isError ? Palette.dim : Palette.mute))
                .font(mono(10)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 2)
            Text(st.timestamp.map { formatDuration(model.now.timeIntervalSince($0)) } ?? "").font(mono(9.5)).foregroundColor(Palette.faint)
        }
    }

    @ViewBuilder var steps: some View {
        if let st = detail?.transcript?.steps.suffix(5), !st.isEmpty {
            VStack(alignment: .leading, spacing: 3) { ForEach(Array(st.reversed()), id: \.id) { stepRow($0) } }
            if let t = detail?.transcript?.lastText {
                Text(t).font(.system(size: 10.5)).foregroundColor(Palette.mute).lineLimit(2)
            }
        } else {
            Text(detail == nil ? "reading…" : "No tool calls yet.").font(mono(10)).foregroundColor(Palette.faint)
        }
    }

    var actions: some View {
        let id = s.sessionId
        let setHint: (String?) -> Void = { model.hint[id] = $0 }
        let bg = s.kind == .background
        let confirming = model.confirmEnd.contains(id)
        return HStack(spacing: 5) {
            SmallButton(title: "Open", color: showsPrompt ? Palette.dim : Palette.accent, tip: openTip, onHint: setHint) { model.open(s) }
                .disabled(model.busy)
            SmallButton(title: bg ? (confirming ? "End agent?" : "End") : "Hide",
                        color: confirming ? Palette.accent : Palette.dim, tip: bg ? endTip : hideTip, onHint: setHint) { model.end(s, item) }
                .disabled(model.busy)
            Spacer(minLength: 4)
            if let f = model.hint[id] ?? model.flash[id] {
                Text(f).font(.system(size: 9.5)).foregroundColor(Palette.mute).lineLimit(2).multilineTextAlignment(.trailing)
            }
        }
    }
}

/// An open hook request: a permission (tool + full input, Approve / Deny / Answer in terminal) or a question
/// (every question, option buttons, an Other field, Send). Buttons call CrewshelfModel.decide -> HookCenter.decide.
struct RequestView: View {
    @ObservedObject var model: CrewshelfModel
    let s: Session
    let req: PendingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(req.kind == .question ? "Question" : req.preview.title).font(mono(10.5, .semibold)).foregroundColor(Palette.accent)
                Text(req.kind == .question ? "" : "wants permission").font(mono(9.5)).foregroundColor(Palette.mute)
                Spacer(minLength: 2)
            }
            if req.kind == .question { questions } else { permission }
            if let more = model.pending[s.sessionId]?.count, more > 1 {
                Text("+\(more - 1) more request\(more > 2 ? "s" : "") after this").font(mono(9.5)).foregroundColor(Palette.mute)
            }
            if !req.hasTerminal {
                Text("No terminal: if you don't answer here, it is denied.").font(.system(size: 9.5)).foregroundColor(Palette.dim)
            }
        }
        .onAppear { model.see(req) }
    }

    @ViewBuilder var permission: some View {
        if let sub = req.preview.subtitle {
            // Never cut here: a long one is already cut (and Approve is off) in permissionPreview.
            Text(sub).font(mono(10)).foregroundColor(Palette.dim).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Only running outside the sandbox gets the solid chip; the other warnings are outlined.
        ForEach(req.preview.warnings, id: \.self) { w in
            let severe = w == sandboxWarning
            Text(w).font(mono(10, .semibold)).foregroundColor(severe ? Palette.eye : Palette.accent)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(severe ? Palette.accent : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.accent.opacity(severe ? 1 : 0.6), lineWidth: 1))
        }
        if !req.preview.body.isEmpty {
            PreviewBody(preview: req.preview, cut: model.bubbleCut)
            if req.preview.lineCount > 12 {
                Text("\(req.preview.lineCount) lines: scroll to read all of it").font(mono(9.5)).foregroundColor(Palette.mute)
            }
        }
        let armed = model.armed(req)
        HStack(spacing: 5) {
            SmallButton(title: "Approve", color: Palette.faint, filled: armed && !req.preview.tooLong,
                        tip: req.preview.tooLong ? "Too long to show in full, so it can't be approved here" : "Let it run this once") {
                model.decide(req, HookDecision(.allow))
            }.disabled(!armed || req.preview.tooLong)
            SmallButton(title: "Deny", color: armed ? Palette.text : Palette.faint, tip: "Refuse; Claude is told you said no") {
                model.decide(req, HookDecision(.deny))
            }.disabled(!armed)
            Spacer(minLength: 2)
            if req.hasTerminal {
                SmallButton(title: "Answer in terminal", tip: "Leave this to the prompt in its terminal tab") {
                    model.decide(req, HookDecision(.terminal))
                }.disabled(!armed)
            }
        }
    }

    var questions: some View {
        let ready = model.answers(req) != nil && model.armed(req)
        let total = req.questions.reduce(CGFloat(0)) { sum, q in
            sum + 48 + q.options.reduce(CGFloat(0)) { $0 + 30 + (($1.description ?? "").isEmpty ? 0 : 13) }
        }
        return VStack(alignment: .leading, spacing: 7) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(req.questions.enumerated()), id: \.offset) { qi, q in question(qi, q) }
                }
            }
            .frame(height: min(max(questionsMinHeight, questionsMaxHeight - model.bubbleCut), total))
            HStack(spacing: 5) {
                SmallButton(title: "Send", color: Palette.faint, filled: ready, tip: "Send these answers to Claude") { model.send(req) }
                    .disabled(!ready)
                Spacer(minLength: 2)
                if req.hasTerminal {
                    SmallButton(title: "Answer in terminal", tip: "Leave this to the question in its terminal tab") {
                        model.decide(req, HookDecision(.terminal))
                    }.disabled(!model.armed(req))
                }
            }
        }
    }

    func question(_ qi: Int, _ q: HookQuestion) -> some View {
        let picked = model.picks[req.id]?[qi] ?? []
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let h = q.header, !h.isEmpty {
                    Text(h).font(mono(9.5, .semibold)).foregroundColor(Palette.dim)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.mute, lineWidth: 1))
                }
                Text(q.question).font(mono(10.5)).foregroundColor(Palette.text).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(q.options.enumerated()), id: \.offset) { _, o in
                ChoiceRow(label: o.label, detail: o.description, selected: picked.contains(o.label), multi: q.multiSelect) {
                    model.togglePick(req, qi, o.label)
                }
            }
            TextField("Other…", text: Binding(
                get: { model.other[req.id]?[qi] ?? "" },
                set: { v in
                    model.other[req.id, default: [:]][qi] = v
                    if !q.multiSelect && !v.isEmpty { model.picks[req.id, default: [:]][qi] = [] }
                }))
                .textFieldStyle(.plain).font(mono(10.5)).foregroundColor(Palette.text)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5).fill(Palette.raised))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.line, lineWidth: 1))
                .onSubmit { model.send(req) }
        }
    }
}

struct BubbleShape: Shape {
    let tail: BubbleTail?
    func path(in r: CGRect) -> Path {
        guard let t = tail else { return Path(roundedRect: r, cornerRadius: 10) }
        let h: CGFloat = 7
        let body = t.top ? CGRect(x: r.minX, y: r.minY + h, width: r.width, height: r.height - h)
                         : CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - h)
        var p = Path(roundedRect: body, cornerRadius: 10)
        let x = min(max(r.minX + t.x, r.minX + 17), r.maxX - 17)
        let base = t.top ? body.minY + 0.5 : body.maxY - 0.5
        p.move(to: CGPoint(x: x - 7, y: base))
        p.addLine(to: CGPoint(x: x, y: t.top ? r.minY : r.maxY))
        p.addLine(to: CGPoint(x: x + 7, y: base))
        p.closeSubpath()
        return p
    }
}

/// The shelf window: characters on a plank. Placed by AppDelegate.layout.
struct ShelfRoot: View {
    @ObservedObject var model: CrewshelfModel
    var body: some View {
        Shelf(model: model)
            .padding(8)
            .environment(\.colorScheme, .dark)
            .onPreferenceChange(FramesKey.self) { f in
                var chars: [String: CGRect] = [:], other: [String: CGRect] = [:]
                for (k, r) in f { if k.hasPrefix("char:") { chars[String(k.dropFirst(5))] = r } else { other[k] = r } }
                model.shelfProbes = other
                if model.charFrames != chars { model.charFrames = chars; model.onLayout?() }
            }
    }
}

/// The bubble window: the one open bubble, on the side of the shelf that faces the screen's center. With no
/// agent bubble open, a notice (first run, settings) takes its place.
struct BubbleRoot: View {
    @ObservedObject var model: CrewshelfModel
    var body: some View {
        Group {
            if !model.collapsed, let item = model.bubbles.open, let s = model.session(item.sessionId) {
                Bubble(model: model, item: item, s: s, tail: model.bubbleTail).id(item.key)
            } else if let n = model.notice {
                NoticeBubble(model: model, notice: n, tail: model.bubbleTail)
            }
        }
        .padding(8)
        .environment(\.colorScheme, .dark)
        .onPreferenceChange(FramesKey.self) { model.probes = $0 }
    }
}

/// The first-run hint ("Install the plugin", with the two commands and Copy) and the settings answers.
struct NoticeBubble: View {
    @ObservedObject var model: CrewshelfModel
    let notice: Notice
    let tail: BubbleTail?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(mono(10.5, .semibold)).foregroundColor(notice == .connected ? Palette.ok : Palette.accent)
                Spacer(minLength: 4)
                Button { model.showNotice(nil) } label: {
                    Text("×").font(mono(12)).foregroundColor(Palette.mute).frame(width: 14, height: 14).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Dismiss").probe("button:×")
            }
            content
        }
        .padding(.horizontal, 11)
        .padding(.top, tail?.top == true ? 17 : 10).padding(.bottom, tail.map { $0.top ? 10 : 17 } ?? 10)
        .frame(width: bubbleWidth, alignment: .leading)
        .background(BubbleShape(tail: tail).fill(Palette.bg))
        .overlay(BubbleShape(tail: tail).stroke(notice == .connected ? Palette.ok.opacity(0.6) : Palette.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
    }

    var title: String {
        switch notice {
        case .install: return "Install the plugin"
        case .connected: return "Plugin connected"
        case .moveToApplications, .loginApproval, .loginError: return "Launch at login"
        }
    }

    func para(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder var content: some View {
        switch notice {
        case .install:
            para("Crewshelf hears from your agents through its Claude Code plugin. Run these two commands in Claude Code:")
            VStack(alignment: .leading, spacing: 2) {
                // A marker per command with a hanging indent, so a wrapped command still reads as one.
                ForEach(pluginInstallCommands, id: \.self) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("›").font(mono(10)).foregroundColor(Palette.mute)
                        Text(c).font(mono(10)).foregroundColor(Palette.text).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Palette.raised).clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .leading) { Rectangle().fill(Palette.accent).frame(width: 2) }
            HStack(spacing: 6) {
                SmallButton(title: "Copy", color: Palette.accent, tip: "Copy both commands") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pluginInstallCommands.joined(separator: "\n"), forType: .string)
                    model.noticeFlash = "Copied. Paste into Claude Code."
                }
                if let f = model.noticeFlash { Text(f).font(.system(size: 9.5)).foregroundColor(Palette.mute) }
                Spacer(minLength: 0)
            }
            Text("New sessions show up here once it is installed.").font(.system(size: 9.5)).foregroundColor(Palette.mute)
        case .connected:
            para("Hook events are arriving. Requests from new sessions open here.")
        case .moveToApplications(let path):
            para("macOS only starts apps at login from Applications. Crewshelf runs from \(shortPath((path as NSString).standardizingPath)). Move Crewshelf.app to /Applications or ~/Applications, open it from there, and turn this on again.")
            HStack(spacing: 6) {
                SmallButton(title: "Show in Finder", color: Palette.accent, tip: "Reveal this copy of Crewshelf") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Spacer(minLength: 0)
            }
        case .loginApproval:
            para("macOS needs you to allow Crewshelf in System Settings > General > Login Items.")
            HStack(spacing: 6) {
                SmallButton(title: "Open Login Items", color: Palette.accent, tip: "System Settings > General > Login Items") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                Spacer(minLength: 0)
            }
        case .loginError(let msg):
            para("Couldn't change it: \(msg)")
        }
    }
}
