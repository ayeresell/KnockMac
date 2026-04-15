import SwiftUI
import AudioToolbox
import CoreGraphics

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var step = 0
    
    // Step 0 (System Check) state
    @State private var hasScreenCapture = CGPreflightScreenCaptureAccess()
    @State private var hasAccelerometer = false
    @State private var sysCheckReader: AccelerometerReader?
    
    // Step 2 (Sensitivity) state
    @State private var sensitivityMags: [Double] = []
    
    // Step 3 (Speed) state
    @State private var speedGaps: [Double] = []
    @State private var speedMags: [Double] = []
    
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
                                        let granted = CGRequestScreenCaptureAccess()
                                        hasScreenCapture = granted
                                        if !granted {
                                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                                        }
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
                        
                        Spacer()
                        
                        Button("Continue") {
                            withAnimation { step = 1 }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!hasAccelerometer || !hasScreenCapture)
                    }
                    .padding(40)
                    .transition(.opacity)
                    .onAppear {
                        runSystemCheck()
                    }
                    .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
                        if !hasScreenCapture {
                            hasScreenCapture = CGPreflightScreenCaptureAccess()
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
                    // Step 2: Calibration - Sensitivity
                    VStack(spacing: 20) {
                        Text("Step 1: Sensitivity")
                            .font(.title)
                            .fontWeight(.bold)
                        
                        Text("Knock ONCE firmly on your Mac.")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        
                        Text("We need to learn your natural knocking force.\nPlease do this 3 times.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        if sensitivityMags.count == 3 {
                            VStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 60))
                                    .foregroundColor(.green)
                                Text("Great! Force recorded.")
                                    .font(.headline)
                                Text("Average force: \(String(format: "%.3f", sensitivityMags.reduce(0, +) / 3.0))g")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            VStack {
                                ProgressView()
                                    .scaleEffect(1.5)
                                    .padding()
                                Text("Waiting for knock \(sensitivityMags.count + 1) of 3...")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Spacer()
                        
                        Button("Next") {
                            withAnimation { step = 3 }
                            startSpeedCalibration()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(sensitivityMags.count < 3)
                    }
                    .padding(40)
                    .transition(.opacity)
                } else if step == 3 {
                    // Step 3: Calibration - Speed
                    VStack(spacing: 20) {
                        Text("Step 2: Speed")
                            .font(.title)
                            .fontWeight(.bold)
                        
                        Text("Now DOUBLE-KNOCK with your natural speed.")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        
                        Text("We will measure the gap between your knocks.\nPlease do this 3 times.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        if speedGaps.count == 3 {
                            VStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 60))
                                    .foregroundColor(.green)
                                Text("Perfect! Speed recorded.")
                                    .font(.headline)
                                Text("Average gap: \(String(format: "%.3f", speedGaps.reduce(0, +) / 3.0))s")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            VStack {
                                ProgressView()
                                    .scaleEffect(1.5)
                                    .padding()
                                Text("Waiting for double-knock \(speedGaps.count + 1) of 3...")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Spacer()
                        
                        Button("Finish") {
                            finishOnboarding()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(speedGaps.count < 3)
                    }
                    .padding(40)
                    .transition(.opacity)
                }
            }
        }
        .frame(width: 500, height: 400)
        .onDisappear {
            stopCalibration()
            sysCheckReader?.stop()
        }
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
    
    private func startSensitivityCalibration() {
        stopCalibration()
        sensitivityMags.removeAll()
        
        let reader = AccelerometerReader()
        let detector = KnockDetector()
        
        // Very sensitive, gap doesn't matter since we only look at single knocks
        detector.setCalibrationMode(threshold: 0.02, maxGap: 1.0)
        
        detector.onSingleKnock = { mag in
            DispatchQueue.main.async {
                guard self.sensitivityMags.count < 3 else { return }
                self.sensitivityMags.append(mag)
                AudioServicesPlaySystemSound(1108) // Shutter sound
                
                if self.sensitivityMags.count == 3 {
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
    
    private func startSpeedCalibration() {
        stopCalibration()
        speedGaps.removeAll()
        speedMags.removeAll()
        
        let reader = AccelerometerReader()
        let detector = KnockDetector()
        
        // Use average of sensitivity mags temporarily to be realistic
        let avgSensitivity = sensitivityMags.isEmpty ? 0.06 : (sensitivityMags.reduce(0, +) / Double(sensitivityMags.count))
        let temporaryThreshold = max(0.02, min(avgSensitivity * 0.7, 0.20))
        
        detector.setCalibrationMode(threshold: temporaryThreshold, maxGap: 1.5)
        
        detector.onDoubleKnockWithGap = { gap, mag in
            DispatchQueue.main.async {
                guard self.speedGaps.count < 3 else { return }
                self.speedGaps.append(gap)
                self.speedMags.append(mag)
                AudioServicesPlaySystemSound(1108) // Shutter sound
                
                if self.speedGaps.count == 3 {
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
        
        // Calculate final threshold based on all recorded magnitudes
        let allMags = sensitivityMags + speedMags
        if !allMags.isEmpty {
            let avgMag = allMags.reduce(0, +) / Double(allMags.count)
            // Save threshold (e.g. 70% of their average tap force, bounded)
            let newThreshold = max(0.02, min(avgMag * 0.7, 0.20))
            UserDefaults.standard.set(newThreshold, forKey: "knockThreshold")
            print("[Onboarding] Final calibrated threshold to \(newThreshold)")
        }
        
        // Calculate final speed gap based on recorded gaps
        if !speedGaps.isEmpty {
            let maxRecordedGap = speedGaps.max() ?? 0.45
            // Save gap + 0.15s buffer (max 0.8s)
            let newMaxGap = min(maxRecordedGap + 0.15, 0.80)
            UserDefaults.standard.set(newMaxGap, forKey: "knockMaxGap")
            print("[Onboarding] Final calibrated max gap to \(newMaxGap)")
        }
        
        hasCompletedOnboarding = true
        
        // Notify the KnockController to reload settings and start listening
        NotificationCenter.default.post(name: NSNotification.Name("OnboardingCompleted"), object: nil)
        
        // Close window
        NSApp.windows.first(where: { $0.title == "KnockMac Setup" })?.close()
    }
}

// Window manager to present the onboarding view reliably
@MainActor
class OnboardingWindowManager {
    static let shared = OnboardingWindowManager()
    private var window: NSWindow?
    
    func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return }
        
        if window == nil {
            let hostingController = NSHostingController(rootView: OnboardingView())
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.center()
            newWindow.title = "KnockMac Setup"
            newWindow.isReleasedWhenClosed = false
            newWindow.contentViewController = hostingController
            newWindow.level = .floating // Ensure it shows up above other things
            self.window = newWindow
        }
        
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
