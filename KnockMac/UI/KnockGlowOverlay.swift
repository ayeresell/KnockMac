import SwiftUI
import AppKit


// MARK: - Pure animation math

struct GlowPhaseValues {
    let opacity: CGFloat
}

/// Returns animation values at a given elapsed time (seconds) since `flash()`.
/// Envelope (total 0.40s):
/// - 0.00 → 0.08s: fade in (opacity 0→1, ease-out quad)
/// - 0.08 → 0.23s: hold (opacity 1)
/// - 0.23 → 0.40s: fade out (opacity 1→0, ease-in quad)
/// - outside [0, 0.40]: opacity 0
func glowPhase(elapsed: TimeInterval) -> GlowPhaseValues {
    let fadeInEnd: TimeInterval = 0.08
    let holdEnd: TimeInterval   = 0.23
    let totalEnd: TimeInterval  = 0.40

    let opacity: CGFloat

    if elapsed <= 0 {
        opacity = 0
    } else if elapsed < fadeInEnd {
        let t = CGFloat(elapsed / fadeInEnd)
        let eased = 1 - (1 - t) * (1 - t)   // ease-out quad
        opacity = eased
    } else if elapsed < holdEnd {
        opacity = 1
    } else if elapsed < totalEnd {
        let t = CGFloat((elapsed - holdEnd) / (totalEnd - holdEnd))
        let eased = t * t                    // ease-in quad
        opacity = 1 - eased
    } else {
        opacity = 0
    }

    return GlowPhaseValues(opacity: opacity)
}

// MARK: - State

@MainActor
final class GlowState: ObservableObject {
    @Published var startDate: Date?
}

// MARK: - View

struct KnockGlowView: View {
    @ObservedObject var state: GlowState

    var body: some View {
        // Short-circuit when inactive: no TimelineView ticks.
        if let start = state.startDate {
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(start)
                let phase = glowPhase(elapsed: elapsed)

                ZStack {
                    // Bloom — soft falloff around the rim.
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(glowColor, lineWidth: 6)
                        .blur(radius: 24)
                        .opacity(0.85)

                    // Rim — crisp neon edge.
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(glowColor, lineWidth: 2)
                        .blur(radius: 1)
                        .opacity(1.0)
                }
                .drawingGroup()
                .opacity(phase.opacity)
                .clipped()
                .allowsHitTesting(false)
            }
        } else {
            Color.clear
        }
    }
}

/// Apple system blue (`#007AFF`).
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

        // Eager window construction — avoids a ~100 ms stall on the first
        // knock after launch/onboarding. Deferred one runloop tick so we
        // don't construct an NSWindow during `KnockController.init()`, which
        // runs very early in app startup.
        DispatchQueue.main.async { [weak self] in
            self?.ensureWindow()
        }
    }

    // No deinit: this is a `static let shared` singleton, alive for process lifetime.

    func flash() {
        animationTask?.cancel()
        ensureWindow()
        state.startDate = Date()
        window?.orderFrontRegardless()

        animationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.40))
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
