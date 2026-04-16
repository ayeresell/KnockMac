import SwiftUI
import AudioToolbox
import CoreGraphics

struct OnboardingView: View {
    var startAtStep: Int = 0

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var step = 0

    // Step 0 (System Check) state
    @State private var hasScreenCapture = false
    @State private var hasAccelerometer = false
    @State private var sysCheckReader: AccelerometerReader?

    // Animated system check
    @State private var checks: [SystemCheck] = SystemCheck.initial()
    @State private var statusLine: String = "Initializing diagnostics…"
    @State private var scanProgress: Double = 0
    @State private var iconPulse: Bool = false
    @State private var checksStarted: Bool = false

    // Step 2 (Verify) state
    @State private var verifyKnockCount: Int = 0
    
    // Local knock detector just for calibration
    @State private var calibrationReader: AccelerometerReader?
    @State private var calibrationDetector: KnockDetector?

    var body: some View {
        VStack {
            Group {
                if step == 0 {
                    // Step 0: Animated System Check
                    VStack(spacing: 16) {
                        Image(systemName: "laptopcomputer.and.iphone")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 72, height: 72)
                            .foregroundColor(.blue)
                            .scaleEffect(iconPulse ? 1.05 : 1.0)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: iconPulse)

                        Text("System Check")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        HStack(spacing: 6) {
                            if !allChecksFinished {
                                ProgressView().scaleEffect(0.55)
                            } else if allChecksPassed {
                                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                            }
                            Text(statusLine)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .animation(.easeOut(duration: 0.2), value: statusLine)
                        }
                        .frame(height: 20)

                        VStack(spacing: 10) {
                            ForEach(checks.indices, id: \.self) { idx in
                                SystemCheckRow(check: checks[idx]) {
                                    NSApp.windows.first(where: { $0.title.hasPrefix("KnockMac") })?.level = .normal
                                    CGRequestScreenCaptureAccess()
                                }
                                .transition(.opacity)
                            }
                        }
                        .padding(14)
                        .frame(width: 420)
                        .background(Color.secondary.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                        )
                        .cornerRadius(10)

                        Spacer(minLength: 0)

                        if allChecksPassed {
                            Button("Continue") {
                                withAnimation { step = 1 }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .transition(.opacity.combined(with: .scale))
                        }
                    }
                    .padding(30)
                    .transition(.opacity)
                    .onAppear {
                        iconPulse = true
                        refreshScreenCaptureAccess()
                        if !checksStarted {
                            checksStarted = true
                            runSystemCheck()
                            runAnimatedDiagnostic()
                        }
                    }
                    .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
                        if !hasScreenCapture { refreshScreenCaptureAccess() }
                    }
                    .onChange(of: hasScreenCapture) { _, granted in
                        updateCheck(id: "permission", granted: granted)
                        if granted {
                            NSApp.windows.first(where: { $0.title.hasPrefix("KnockMac") })?.level = .floating
                        }
                    }
                    .onChange(of: hasAccelerometer) { _, ok in
                        updateCheck(id: "sensor", granted: ok)
                    }
                } else if step == 1 {
                    // Step 1: Explanation
                    VStack(spacing: 20) {
                        Text("Where to knock")
                            .font(.title)
                            .fontWeight(.bold)
                        
                        // Stylized MacBook drawing with highlight
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(nsColor: .windowBackgroundColor))
                                .frame(width: 300, height: 200)
                                .shadow(radius: 5)
                            
                            // Keyboard area
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 260, height: 90)
                                .offset(y: -10)
                            
                            // Trackpad area
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 100, height: 60)
                                .offset(y: 70)
                            
                            // Touch Bar area
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.blue.opacity(0.5))
                                .frame(width: 260, height: 24)
                                .offset(y: -75)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.blue, lineWidth: 2).offset(y: -75))
                                .overlay(Text("Tap Here").font(.caption2).bold().foregroundColor(.blue).offset(y: -75))
                        }
                        .padding(.vertical, 10)
                        
                        Text("Firmly double-knock between the screen and the keyboard (where the Touch Bar would be).\nIt works elsewhere too, but the sensor is most sensitive there.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        Spacer()
                        
                        Button("Next") {
                            withAnimation { step = 2 }
                            startVerificationCalibration()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .padding(40)
                    .transition(.opacity)
                } else if step == 2 {
                    // Step 2: Verify
                    VStack(spacing: 20) {
                        Text("Step 2: Test it out")
                            .font(.title)
                            .fontWeight(.bold)

                        Text("Double-knock 3 times to confirm\nyour settings work.")
                            .font(.headline)
                            .multilineTextAlignment(.center)

                        Spacer()

                        // Progress dots
                        HStack(spacing: 16) {
                            ForEach(0..<3) { i in
                                Circle()
                                    .fill(verifyKnockCount > i ? Color.green : Color.secondary.opacity(0.2))
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundColor(.white)
                                            .opacity(verifyKnockCount > i ? 1 : 0)
                                    )
                                    .animation(.easeOut(duration: 0.25), value: verifyKnockCount)
                            }
                        }

                        ZStack {
                            Circle()
                                .fill(verifyKnockCount >= 3 ? Color.green.opacity(0.25) : Color.secondary.opacity(0.08))
                                .frame(width: 90, height: 90)
                                .animation(.easeOut(duration: 0.35), value: verifyKnockCount)
                            Image(systemName: verifyKnockCount >= 3 ? "checkmark" : "hand.tap.fill")
                                .font(.system(size: 38))
                                .foregroundColor(verifyKnockCount >= 3 ? .green : .secondary)
                                .animation(.easeOut(duration: 0.35), value: verifyKnockCount)
                        }

                        if verifyKnockCount >= 3 {
                            Text("All done!")
                                .font(.headline)
                                .foregroundColor(.green)
                        } else {
                            Text("Knock \(verifyKnockCount + 1) of 3…")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        HStack {
                            Button("Back") {
                                verifyKnockCount = 0
                                withAnimation { step = 1 }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            Spacer()

                            Button("Finish") {
                                finishOnboarding()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(verifyKnockCount < 3)
                        }
                    }
                    .padding(40)
                    .transition(.opacity)
                }
            }
        }
        .frame(width: 500, height: 480)
        .onAppear {
            if startAtStep > 0 {
                step = startAtStep
            }
        }
        .onDisappear {
            stopCalibration()
            sysCheckReader?.stop()
        }
    }
    
    private func refreshScreenCaptureAccess() {
        hasScreenCapture = CGPreflightScreenCaptureAccess()
    }

    private func runSystemCheck() {
        guard !hasAccelerometer else { return }
        sysCheckReader = AccelerometerReader()
        sysCheckReader?.onSample = { _ in
            DispatchQueue.main.async {
                if !self.hasAccelerometer {
                    self.hasAccelerometer = true
                    self.sysCheckReader?.stop()
                    self.sysCheckReader = nil
                }
            }
        }
    }
    
    private func startVerificationCalibration() {
        stopCalibration()
        verifyKnockCount = 0

        let reader = AccelerometerReader()
        let detector = KnockDetector()
        // Shorter than production 1.0s so rapid sequential double-knocks
        // during verification aren't swallowed by cooldown. Still longer
        // than maxGap (0.325s) to avoid chassis-resonance re-triggers.
        detector.cooldown = 0.4

        detector.onDoubleKnockWithGap = { _, _ in
            DispatchQueue.main.async {
                guard self.verifyKnockCount < 3 else { return }
                self.verifyKnockCount += 1
                AudioServicesPlaySystemSound(1108)
                if self.verifyKnockCount >= 3 {
                    self.stopCalibration()
                }
            }
        }

        reader.onSample = { sample in
            detector.feed(sample)
        }

        self.calibrationReader = reader
        self.calibrationDetector = detector
    }
    
    private func stopCalibration() {
        calibrationReader?.stop()
        calibrationReader = nil
        calibrationDetector = nil
    }
    
    private func finishOnboarding() {
        stopCalibration()

        hasCompletedOnboarding = true

        // Notify the KnockController to reload settings and start listening
        NotificationCenter.default.post(name: NSNotification.Name("OnboardingCompleted"), object: nil)

        // Give SwiftUI a moment to insert the MenuBarExtra (isInserted just became true)
        // before this window closes. Without the delay the app briefly has no active
        // scenes and applicationShouldTerminate may fire before the icon is registered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            OnboardingWindowManager.shared.closeWindow()
        }
    }
}

// Window manager to present the onboarding view reliably
@MainActor
class OnboardingWindowManager {
    static let shared = OnboardingWindowManager()
    private var window: NSWindow?
    
    func showIfNeeded() {
        guard !KnockController.hasRequiredPermissions() else { return }
        show(title: "KnockMac Setup")
    }

    func showSettings() {
        // Close and discard existing window so a fresh OnboardingView is created.
        window?.close()
        window = nil
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        show(title: "KnockMac Settings", startAtStep: 0)
    }

    func closeWindow() {
        window?.close()
    }

    private func show(title: String, startAtStep: Int = 0) {
        if window == nil {
            let hostingController = NSHostingController(rootView: OnboardingView(startAtStep: startAtStep))
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.title = title
            newWindow.isReleasedWhenClosed = false
            newWindow.contentViewController = hostingController
            newWindow.level = .floating
            newWindow.center()
            self.window = newWindow
        } else {
            window?.title = title
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            if let window = self.window, let screen = window.screen ?? NSScreen.main {
                let screenFrame = screen.frame
                let windowFrame = window.frame
                let x = screenFrame.midX - windowFrame.width / 2
                let y = screenFrame.midY - windowFrame.height / 2
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
    }
}
