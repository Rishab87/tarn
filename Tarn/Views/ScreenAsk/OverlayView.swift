import AppKit
import SwiftUI

/// Full-screen, borderless window over one display. Non-activating, so the app you were using
/// stays frontmost; it still becomes key so Esc reaches it.
final class OverlayPanel: NSPanel {
    var onEscape: (() -> Void)?

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// The glow palette: Tarn's water colour, lifted toward light. Original to Tarn.
enum Glow {
    static let deep = Color(red: 0.18, green: 0.49, blue: 0.54)
    static let water = Color(red: 0.42, green: 0.72, blue: 0.76)
    static let foam = Color(red: 0.74, green: 0.93, blue: 0.94)
    static let ring: [Color] = [water, foam, .white, foam, water, deep.opacity(0.6), water]
}

/// What the overlay shows: the frozen screen, a ripple from the pointer like a stone dropped in
/// still water, a slow glow around the display's edge, and the loop the user draws.
struct OverlayView: View {
    let image: CGImage
    let pixelsPerPoint: CGFloat
    /// Where the ripple starts (the pointer), in view points.
    let origin: CGPoint
    let mode: CaptureMode
    var onSelect: (CGRect) -> Void
    var onCancel: () -> Void
    /// A stroke started (true) or ended without a selection (false); the failsafe waits for it.
    var onDrawing: (Bool) -> Void
    /// Debug renders: a fixed state, no animation.
    struct Preset {
        var points: [CGPoint]
        var selection: CGRect?
        /// Ripple frozen at this fraction of its travel.
        var ripple: CGFloat?
    }
    var preset: Preset?

    @State private var appeared = false
    @State private var rippled = false
    @State private var spin = 0.0
    @State private var points: [CGPoint] = []
    @State private var selection: CGRect?
    @State private var settled = false

    init(image: CGImage, pixelsPerPoint: CGFloat, origin: CGPoint, mode: CaptureMode,
         onSelect: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void,
         onDrawing: @escaping (Bool) -> Void = { _ in }, preset: Preset? = nil) {
        self.image = image
        self.pixelsPerPoint = pixelsPerPoint
        self.origin = origin
        self.mode = mode
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.onDrawing = onDrawing
        self.preset = preset
        if let preset {
            _points = State(initialValue: preset.points)
            _selection = State(initialValue: preset.selection)
            _appeared = State(initialValue: true)
            _rippled = State(initialValue: true)
            _settled = State(initialValue: true)
            _spin = State(initialValue: 35)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let diag = (size.width * size.width + size.height * size.height).squareRoot()
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: pixelsPerPoint)
                    .resizable()
                    .frame(width: size.width, height: size.height)

                DimMask(hole: selection)
                    .fill(Color.black.opacity(selection == nil ? (appeared ? 0.16 : 0) : 0.46), style: FillStyle(eoFill: true))
                    .animation(.easeOut(duration: 0.3), value: selection)

                ripple(diag: diag, delay: 0, width: 2.5)
                ripple(diag: diag, delay: 0.12, width: 1.2)

                edgeGlow(size: size, diag: diag)

                if selection == nil, points.count > 1 {
                    let path = Path { $0.addLines(points) }
                    path.stroke(Glow.water, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round)).blur(radius: 7).opacity(0.9)
                    path.stroke(LinearGradient(colors: [Glow.water, Glow.foam], startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    path.stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                }

                if let s = selection {
                    // Glow sits just outside the edge so the circled content stays crisp.
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Glow.foam, lineWidth: 5).blur(radius: 5)
                        .frame(width: s.width + 10, height: s.height + 10).offset(x: s.minX - 5, y: s.minY - 5)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white, lineWidth: 1.6)
                        .frame(width: s.width, height: s.height).offset(x: s.minX, y: s.minY)
                        .scaleEffect(settled ? 1 : 1.04, anchor: UnitPoint(x: s.midX / max(size.width, 1), y: s.midY / max(size.height, 1)))
                }

                hint
                    .frame(width: size.width)
                    .offset(y: max(36, (NSScreen.main?.safeAreaInsets.top ?? 0) + 30))
                    .opacity(appeared && selection == nil && points.isEmpty ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: points.isEmpty)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(draw(in: size))
        }
        .ignoresSafeArea()
        .onAppear(perform: enter)
    }

    private func ripple(diag: CGFloat, delay: Double, width: CGFloat) -> some View {
        Circle()
            .stroke(AngularGradient(colors: Glow.ring, center: .center), lineWidth: width)
            .shadow(color: Glow.foam.opacity(0.8), radius: 6)
            .frame(width: diag * 2, height: diag * 2)
            .scaleEffect(preset?.ripple ?? (rippled ? 1 : 0.01))
            .opacity(preset?.ripple.map { 1 - $0 } ?? (rippled ? 0 : 0.95))
            .position(origin)
            .animation(.easeOut(duration: 1.1).delay(delay), value: rippled)
            .allowsHitTesting(false)
    }

    private func edgeGlow(size: CGSize, diag: CGFloat) -> some View {
        AngularGradient(colors: Glow.ring, center: .center)
            .frame(width: diag, height: diag)
            .rotationEffect(.degrees(spin))
            .frame(width: size.width, height: size.height)
            .mask(Rectangle().strokeBorder(lineWidth: 9).blur(radius: 7))
            .opacity(appeared ? (selection == nil ? 0.85 : 0.35) : 0)
            .animation(.easeOut(duration: 0.45), value: appeared)
            .animation(.easeOut(duration: 0.3), value: selection)
            .allowsHitTesting(false)
    }

    private var hint: some View {
        HStack(spacing: 10) {
            Image(systemName: "lasso").font(.system(size: 13, weight: .semibold))
            Text(mode == .append ? "Circle another part to add it to your question" : "Circle or drag around anything to ask Tarn about it")
                .font(.system(size: 13, weight: .medium))
            Text("esc").font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.white.opacity(0.18), in: .rect(cornerRadius: 5))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.42), in: .capsule)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
    }

    private func draw(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { v in
                guard selection == nil else { return }
                if points.isEmpty {
                    points = [v.startLocation]
                    onDrawing(true)
                }
                if let last = points.last, hypot(last.x - v.location.x, last.y - v.location.y) < 2 { return }
                points.append(v.location)
            }
            .onEnded { _ in
                guard selection == nil else { return }
                onDrawing(false)
                guard let s = ScreenGeometry.selection(from: points, in: size) else {
                    withAnimation(.easeOut(duration: 0.2)) { points = [] }
                    return
                }
                select(s)
            }
    }

    private func select(_ s: CGRect) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { selection = s }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7).delay(0.05)) { settled = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { onSelect(s) }
    }

    private func enter() {
        if preset != nil { return }
        withAnimation(.easeOut(duration: 0.25)) { appeared = true }
        rippled = true
        withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) { spin = 360 }
    }
}

/// The whole display with a rounded hole where the selection is (even-odd fill).
private struct DimMask: Shape {
    var hole: CGRect?

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            let h = hole ?? .zero
            return AnimatablePair(AnimatablePair(h.minX, h.minY), AnimatablePair(h.width, h.height))
        }
        set {
            guard hole != nil else { return }
            hole = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        if let hole, hole.width > 0 { p.addRoundedRect(in: hole, cornerSize: CGSize(width: 12, height: 12), style: .continuous) }
        return p
    }
}
