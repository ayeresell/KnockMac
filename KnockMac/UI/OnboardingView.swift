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
    
    // Step 2 (Sensitivity) state
    // 0 = least sensitive (threshold 0.10g), 1 = most sensitive (threshold 0.02g)
    @State private var sensitivitySlider: Double = 0.5
    @State private var knockFlash: Bool = false
    @State private var knockMarkerPos: Double = 0
    @State private var knockMarkerOpacity: Double = 0
    
    // Step 3 (Verify) state
    @State private var verifyKnockCount: Int = 0
    
    // Local knock detector just for calibration
    @State private var calibrationReader: AccelerometerReader?
    @State private var calibrationDetector: KnockDetector?

    var body: some View {
        VStack {
            Group {
                if step == 0 {
                    // Step 0: Welcome & System Check
                    VStack(spacing: 20) {
                        Image(systemName: "laptopcomputer.and.iphone")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 80, height: 80)
                            .foregroundColor(.blue)
                        
                        Text("System Check")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text("Take screenshots just by double-knocking your Mac.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 10)
                        
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.blue)
                                    .frame(width: 24)
                                Text("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                            }
                            
                            HStack {
                                Image(systemName: hasAccelerometer ? "checkmark.circle.fill" : "circle.dashed")
                                    .foregroundColor(hasAccelerometer ? .green : .gray)
                                    .frame(width: 24)
                                Text("Accelerometer (Apple Silicon)")
                                Spacer()
                                if !hasAccelerometer {
                                    ProgressView().scaleEffect(0.6)
                                }
                            }
                            
                            HStack {
                                Image(systemName: hasScreenCapture ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundColor(hasScreenCapture ? .green : .orange)
                                    .frame(width: 24)
                                Text("Screen Recording")
                                Spacer()
                                if !hasScreenCapture {
                                    Button("Grant") {
                                        // Lower window so TCC dialog appears above; level restored via onChange(of: hasScreenCapture)
                                        NSApp.windows.first(where: { $0.title == "KnockMac Setup" })?.level = .normal
                                        CGRequestScreenCaptureAccess()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding()
                        .frame(width: 380)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(12)
                        
                        Spacer(minLength: 0)

                        if hasAccelerometer && hasScreenCapture {
                            Button("Continue") {
                                withAnimation { step = 1 }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .padding(.bottom, 20)
                        }
                    }
                    .padding(40)
                    .transition(.opacity)
                    .onAppear {
                        runSystemCheck()
                        refreshScreenCaptureAccess()
                    }
                    .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
                        if !hasScreenCapture {
                            refreshScreenCaptureAccess()
                        }
                    }
                    .onChange(of: hasScreenCapture) { _, granted in
                        if granted {
                            NSApp.windows.first(where: { $0.title == "KnockMac Setup" })?.level = .floating
                        }
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
                            startSensitivityCalibration()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .padding(40)
                    .transition(.opacity)
                } else if step == 2 {
                    // Step 2: Sensitivity slider
                    VStack(spacing: 20) {
                        Text("Step 1: Sensitivity")
                            .font(.title)
                            .fontWeight(.bold)

                        Text("Knock on your Mac and adjust the slider\nuntil it feels right.")
                            .font(.headline)
                            .multilineTextAlignment(.center)

                        Text("Too many false triggers → move left.\nKnocks not detected → move right.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)

                        Spacer()

                        // Knock indicator
                        ZStack {
                            Circle()
                                .fill(knockFlash ? Color.green.opacity(0.25) : Color.secondary.opacity(0.08))
                                .frame(width: 90, height: 90)
                                .animation(.easeOut(duration: 0.35), value: knockFlash)
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 38))
                                .foregroundColor(knockFlash ? .green : .secondary)
                                .animation(.easeOut(duration: 0.35), value: knockFlash)
                        }

                        // Slider
                        VStack(spacing: 8) {
                            HStack {
                                Spacer()
                                Text(sensitivityLabel)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(sensitivityLabelColor)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(sensitivityLabelColor.opacity(0.12))
                                    .cornerRadius(6)
                                Spacer()
                            }

                            ZStack {
                                Slider(value: $sensitivitySlider, in: 0...1)
                                // Knock marker: shows where the detected tap falls on the scale
                                GeometryReader { geo in
                                    let thumb: CGFloat = 11
                                    let x = thumb + (geo.size.width - thumb * 2) * knockMarkerPos
                                    Capsule()
                                        .fill(Color.green)
                                        .frame(width: 4, height: 18)
                                        .position(x: x, y: geo.size.height / 2)
                                        .opacity(knockMarkerOpacity)
                                        .animation(.easeOut(duration: 0.15), value: knockMarkerPos)
                                }
                                .allowsHitTesting(false)
                            }
                            HStack {
                                Text("Less sensitive")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("More sensitive")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 8)

                        Spacer()

                        Button("Next") {
                            withAnimation { step = 3 }
                            startVerificationCalibration()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .padding(40)
                    .transition(.opacity)
                    .onAppear { startSensitivityCalibration() }
                } else if step == 3 {
                    // Step 3: Verify
                    VStack(spacing: 20) {
                        Text("Step 2: Test it out")
                            .font(.title)
                            .fontWeight(.bold)

                        Text("Double-knock to confirm\nyour settings work.")
                            .font(.headline)
                            .multilineTextAlignment(.center)

                        Spacer()

                        ZStack {
                            Circle()
                                .fill(verifyKnockCount > 0 ? Color.green.opacity(0.25) : Color.secondary.opacity(0.08))
                                .frame(width: 90, height: 90)
                                .animation(.easeOut(duration: 0.35), value: verifyKnockCount)
                            Image(systemName: verifyKnockCount > 0 ? "checkmark" : "hand.tap.fill")
                                .font(.system(size: 38))
                                .foregroundColor(verifyKnockCount > 0 ? .green : .secondary)
                                .animation(.easeOut(duration: 0.35), value: verifyKnockCount)
                        }

                        if verifyKnockCount > 0 {
                            Text("Works perfectly!")
                                .font(.headline)
                                .foregroundColor(.green)
                        } else {
                            Text("Waiting for double-knock…")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button("Finish") {
                            finishOnboarding()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(verifyKnockCount < 1)
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
    
    // Maps slider 0…1 → threshold 0.10g…0.028g
    private var sliderThreshold: Double {
        0.10 - sensitivitySlider * 0.072
    }

    private var sensitivityLabel: String {
        let t = sliderThreshold
        switch t {
        case ..<0.04: return "Very sensitive — light touch"
        case ..<0.06: return "Sensitive — gentle knock"
        case ..<0.08: return "Medium — normal knock"
        default:       return "Firm knock required"
        }
    }

    private var sensitivityLabelColor: Color {
        let t = sliderThreshold
        switch t {
        case ..<0.04: return .blue
        case ..<0.06: return .green
        case ..<0.08: return .orange
        default:       return .red
        }
    }

    private func startSensitivityCalibration() {
        stopCalibration()
        NotificationCenter.default.post(name: NSNotification.Name("OnboardingStarted"), object: nil)

        let reader = AccelerometerReader()
        let detector = KnockDetector()
        // Always use minimum threshold during sensitivity calibration so ALL knocks
        // are detected regardless of slider position. The slider is purely visual here —
        // it sets the saved threshold, not the detection threshold.
        detector.setCalibrationMode(threshold: 0.02)
        detector.singleKnockOnly = true

        detector.onSingleKnock = { deviation in
            DispatchQueue.main.async {
                AudioServicesPlaySystemSound(1108)
                self.knockFlash = true
                // Position marker: (0.10 - deviation) / 0.08 maps deviation → slider space.
                // Strong knock (high deviation) → marker left; light knock → marker right.
                self.knockMarkerPos = min(1.0, max(0.0, (0.10 - deviation) / 0.072))
                self.knockMarkerOpacity = 1.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.knockFlash = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeOut(duration: 0.6)) {
                        self.knockMarkerOpacity = 0
                    }
                }
            }
        }

        reader.onSample = { sample in
            detector.feed(sample)
        }

        self.calibrationReader = reader
        self.calibrationDetector = detector
    }

    private func startVerificationCalibration() {
        stopCalibration()
        verifyKnockCount = 0

        let reader = AccelerometerReader()
        let detector = KnockDetector()
        detector.setCalibrationMode(threshold: sliderThreshold)

        detector.onDoubleKnockWithGap = { _, _ in
            DispatchQueue.main.async {
                self.verifyKnockCount += 1
                AudioServicesPlaySystemSound(1108)
                if self.verifyKnockCount >= 1 {
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
        
        // Save with 25% headroom so natural force variation still registers.
        // Clamped: 0.028g (floor) … 0.10g (ceiling).
        let finalThreshold = min(0.10, max(0.028, sliderThreshold * 0.75))
        UserDefaults.standard.set(finalThreshold, forKey: "knockThreshold")
        print("[Onboarding] Final calibrated threshold to \(finalThreshold) (slider was \(sliderThreshold))")
        
        hasCompletedOnboarding = true

        // Notify the KnockController to reload settings and start listening
        NotificationCenter.default.post(name: NSNotification.Name("OnboardingCompleted"), object: nil)

        // Give SwiftUI a moment to insert the MenuBarExtra (isInserted just became true)
        // before this window closes. Without the delay the app briefly has no active
        // scenes and applicationShouldTerminate may fire before the icon is registered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.windows.first(where: { $0.title == "KnockMac Setup" })?.close()
        }
    }
}

// Window manager to present the onboarding view reliably
@MainActor
class OnboardingWindowManager {
    static let shared = OnboardingWindowManager()
    private var window: NSWindow?
    
    func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return }
        show()
    }

    func resetAndShow() {
        // Close and discard existing window so a fresh OnboardingView is created.
        window?.close()
        window = nil
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        show(startAtStep: 1)
    }

    private func show(startAtStep: Int = 0) {
        if window == nil {
            let hostingController = NSHostingController(rootView: OnboardingView(startAtStep: startAtStep))
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "KnockMac Setup"
            newWindow.isReleasedWhenClosed = false
            newWindow.contentViewController = hostingController
            newWindow.level = .floating
            newWindow.center()
            self.window = newWindow
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
