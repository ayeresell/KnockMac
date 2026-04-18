import SwiftUI
import AppKit


// MARK: - Pure animation math

struct GlowPhaseValues {
    let opacity: CGFloat
    let rotation: Angle
    let scale: CGFloat
}

/// Returns animation values at a given elapsed time (seconds) since `flash()`.
/// Envelope:
/// - 0.00 → 0.25s: fade in (opacity 0→1, scale 1.05→1.00, ease-out)
/// - 0.25 → 1.30s: hold (opacity 1, scale 1.00)
/// - 1.30 → 1.55s: fade out (opacity 1→0, ease-in, scale 1.00)
/// - Rotation: continuous 360°/2.5s, unwrapped. View uses `AngularGradient`
///   which takes angle modulo 2π, so unwrapping here is fine.
func glowPhase(elapsed: TimeInterval) -> GlowPhaseValues {
    let fadeInEnd: TimeInterval  = 0.25
    let holdEnd: TimeInterval    = 1.30
    let totalEnd: TimeInterval   = 1.55
    let rotationPeriod: TimeInterval = 2.5

    let opacity: CGFloat
    let scale: CGFloat

    if elapsed <= 0 {
        opacity = 0
        scale = 1.05
    } else if elapsed < fadeInEnd {
        let t = CGFloat(elapsed / fadeInEnd)
        let eased = 1 - (1 - t) * (1 - t)   // ease-out quad
        opacity = eased
        scale = 1.05 - 0.05 * eased
    } else if elapsed < holdEnd {
        opacity = 1
        scale = 1.0
    } else if elapsed < totalEnd {
        let t = CGFloat((elapsed - holdEnd) / (totalEnd - holdEnd))
        let eased = t * t                    // ease-in quad
        opacity = 1 - eased
        scale = 1.0
    } else {
        opacity = 0
        scale = 1.0
    }

    let rotationRadians = (elapsed / rotationPeriod) * 2 * .pi
    return GlowPhaseValues(
        opacity: opacity,
        rotation: .radians(rotationRadians),
        scale: scale
    )
}

// MARK: - State

@MainActor
final class GlowState: ObservableObject {
    @Published var startDate: Date?
}

// MARK: - Ring shape

// MARK: - View

struct KnockGlowView: View {
    @ObservedObject var state: GlowState

    var body: some View {
        // Short-circuit when inactive: no TimelineView ticks, no mesh eval.
        if let start = state.startDate {
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(start)
                let phase = glowPhase(elapsed: elapsed)

                ZStack {
                    // Far bloom — widest feather, sets the faintest outer tail.
                    roundedStrokeGlow(line: 8, blur: 180, opacity: 0.5)

                    // Wide halo — fills the gap between far bloom and mid,
                    // making the falloff smooth instead of steppy.
                    roundedStrokeGlow(line: 5, blur: 90, opacity: 0.65)

                    // Mid halo.
                    roundedStrokeGlow(line: 3, blur: 35, opacity: 0.8)

                    // Near-rim glow — builds density near the edge.
                    roundedStrokeGlow(line: 1.5, blur: 8, opacity: 0.95)

                    // Hairline core — crisp bright edge.
                    roundedStrokeGlow(line: 1, blur: 1.5, opacity: 1.0)
                }
                .drawingGroup()
                .opacity(phase.opacity)
                .scaleEffect(phase.scale, anchor: .center)
                .clipped()
                .allowsHitTesting(false)
            }
        } else {
            Color.clear
        }
    }

    /// A single solid-colour glow layer built from a rounded-rectangle
    /// stroke + blur. No gradient, no mask — the stroke's rounded shape
    /// is the only geometry, blur does the rest.
    @ViewBuilder
    private func roundedStrokeGlow(line: CGFloat, blur: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(glowColor, lineWidth: line)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

/// Single blue used across every glow layer. SwiftUI's built-in
/// `Color.blue` is sRGB `#007AFF` — the classic Apple system blue.
private let glowColor: Color = .blue

// MARK: - Window controller

@MainActor
final class KnockGlowWindowController {
    static let shared = KnockGlowWindowController()

    let state = GlowState()
    private var window: NSWindow?
    private var animationTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    private init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateFrame()
            }
        }
    }

    // Note: no `deinit` — this is a `static let shared` singleton that lives
    // for the lifetime of the process. A nonisolated deinit cannot safely
    // read the MainActor-isolated `screenObserver` property under Swift 6
    // strict concurrency, so we rely on process lifetime instead.

    func flash() {
        animationTask?.cancel()
        ensureWindow()
        state.startDate = Date()
        window?.orderFrontRegardless()

        animationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.55))
            guard !Task.isCancelled else { return }
            self?.window?.orderOut(nil)
            self?.state.startDate = nil
        }
    }

    private func ensureWindow() {
        if window != nil { return }
        guard let screen = NSScreen.main else { return }

        let w = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.ignoresMouseEvents = true
        w.sharingType = .none
        w.hasShadow = false
        w.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: KnockGlowView(state: state))
        host.frame = screen.frame
        host.autoresizingMask = [.width, .height]
        w.contentView = host

        window = w
    }

    private func updateFrame() {
        guard let window, let screen = NSScreen.main else { return }
        window.setFrame(screen.frame, display: false)
    }
}
