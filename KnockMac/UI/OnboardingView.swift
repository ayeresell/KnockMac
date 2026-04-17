import SwiftUI
import AudioToolbox
import CoreGraphics

struct OnboardingView: View {
    var startAtStep: Int = 0

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var step = 0

    // Step 0 (System Check) state
    @State private var hasScreenCapture = false
    @State private var needsCaptureRestart = false
    @State private var hasAccelerometer = false
    @State private var sysCheckReader: AccelerometerReader?

    // Animated system check
    @State private var checks: [SystemCheck] = SystemCheck.initial()
    @State private var statusLine: String = "Initializing diagnostics…"
    @State private var scanProgress: Double = 0
    @State private var iconPulse: Bool = false
    @State private var checksStarted: Bool = false
    // Gates the Screen Recording probe until the permission stage begins.
    // Probing via SCShareableContent triggers the TCC dialog on first
    // attempt — we delay that so the user first sees the System Check
    // progress through the other items rather than being hit with the
    // macOS permission prompt at launch.
    @State private var permissionStageStarted: Bool = false

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
                    VStack(spacing: 0) {
                        VStack(spacing: 10) {
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
                                    SystemCheckRow(check: checks[idx])
                                        .transition(.opacity)
                                }
                            }
                            .padding(14)
                            .frame(width: 380)
                            .background(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .fill(.regularMaterial)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .padding(.top, 18)
                        .padding(.horizontal, 24)

                        Spacer(minLength: 0)

                        // Button auto-centers between card and window bottom via flexible spacers.
                        Group {
                            if allChecksPassed {
                                Button("Continue") {
                                    withAnimation { step = 1 }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .buttonBorderShape(.capsule)
                                .transition(.opacity.combined(with: .scale))
                            } else if needsCaptureRestart {
                                Button("Quit & Reopen") {
                                    // After a TCC change, force the user back
                                    // through calibration + verification so
                                    // double-knock detection is re-validated.
                                    UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                                    UserDefaults.standard.synchronize()
                                    ScreenCapturePermission.relaunch()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .buttonBorderShape(.capsule)
                                .transition(.opacity.combined(with: .scale))
                            } else if hasPermissionFailure {
                                Button("Open System Settings") {
                                    requestScreenRecordingAccess()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .buttonBorderShape(.capsule)
                                .transition(.opacity.combined(with: .scale))
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .transition(.opacity)
                    .onAppear {
                        iconPulse = true
                        if !checksStarted {
                            checksStarted = true
                            runSystemCheck()
                            runAnimatedDiagnostic()
                        }
                    }
                    .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
                        if permissionStageStarted && !hasScreenCapture {
                            refreshScreenCaptureAccess()
                        }
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
                        .buttonBorderShape(.capsule)
                    }
                    .padding(.top, 30)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 30)
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
                            .buttonBorderShape(.capsule)

                            Spacer()

                            Button("Finish") {
                                finishOnboarding()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .buttonBorderShape(.capsule)
                            .disabled(verifyKnockCount < 3)
                        }
                    }
                    .padding(.top, 30)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 30)
                    .transition(.opacity)
                }
            }
        }
        .frame(width: 460, height: 480)
        .background(.thickMaterial)
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
        Task {
            let status = await ScreenCapturePermission.currentStatus()
            await MainActor.run {
                applyCaptureStatus(status)
                hasScreenCapture = (status == .granted)
            }
        }
    }

    // When the TCC entry changes mid-session we need the user back in the
    // wizard no matter how the restart happens (our own button or macOS's
    // "Quit & Reopen" prompt). Persisting hasCompletedOnboarding=false
    // immediately ensures showIfNeeded() re-presents onboarding on relaunch.
    private func applyCaptureStatus(_ status: ScreenCapturePermission.Status) {
        let restart = (status == .restartRequired)
        needsCaptureRestart = restart
        if restart {
            UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
            UserDefaults.standard.synchronize()
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

    private var allChecksFinished: Bool {
        checks.allSatisfy { $0.status != .pending && $0.status != .scanning }
    }
    private var allChecksPassed: Bool {
        checks.allSatisfy { $0.status == .passed }
    }
    private var hasPermissionFailure: Bool {
        checks.contains(where: { $0.id == "permission" && $0.status == .failed })
    }

    private func requestScreenRecordingAccess() {
        NSApp.windows.first(where: { $0.title.hasPrefix("KnockMac") })?.level = .normal
        // Registers the bundle in TCC so it appears in the Screen Recording list.
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateCheck(id: String, granted: Bool) {
        guard let idx = checks.firstIndex(where: { $0.id == id }) else { return }
        // Only resolve if we're past this check in the sequence.
        guard checks[idx].status == .scanning || checks[idx].status == .failed else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            checks[idx].status = granted ? .passed : .failed
            if id == "sensor" && granted {
                checks[idx].detail = "Apple Silicon IMU · 100 Hz"
            }
            if id == "permission" && granted {
                checks[idx].detail = "Access granted"
            }
            if id == "permission" && !granted {
                checks[idx].detail = needsCaptureRestart ? "Restart required" : "Permission required"
            }
        }
        advanceStatusLineIfDone()
    }

    private func advanceStatusLineIfDone() {
        if allChecksPassed {
            statusLine = "All systems nominal"
        } else if allChecksFinished {
            statusLine = "Attention required"
        }
    }

    private func runAnimatedDiagnostic() {
        // Stage 1: macOS
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            statusLine = "Detecting operating system…"
            setChecking(id: "macos")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            resolve(id: "macos", detail: SystemInfo.osDescription())
        }

        // Stage 2: Chip
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) {
            statusLine = "Identifying Apple silicon…"
            setChecking(id: "chip")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.10) {
            resolve(id: "chip", detail: SystemInfo.chipDescription())
        }

        // Stage 3: Memory
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
            statusLine = "Measuring unified memory…"
            setChecking(id: "memory")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.60) {
            resolve(id: "memory", detail: SystemInfo.memoryDescription())
        }

        // Stage 4: Motion sensor (waits on real HID detection)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.75) {
            statusLine = "Probing motion sensor at vendor 0x05AC…"
            setChecking(id: "sensor")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.20) {
            statusLine = "Reading IMU sample stream…"
        }
        // Sensor check resolves via onChange(hasAccelerometer) — above callback handles it.
        // Fallback: if still not resolved after 4s, mark failed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            if let idx = checks.firstIndex(where: { $0.id == "sensor" }),
               checks[idx].status == .scanning {
                updateCheck(id: "sensor", granted: false)
                checks[idx].detail = "Sensor not found"
            }
        }

        // Stage 5: Screen recording permission
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.60) {
            statusLine = "Verifying capture permissions…"
            setChecking(id: "permission")
            permissionStageStarted = true
            // Drop the onboarding window from .floating to .normal so the
            // system TCC prompt surfaces above it. Restored to .floating
            // in .onChange(of: hasScreenCapture) once access is granted.
            NSApp.windows.first(where: { $0.title.hasPrefix("KnockMac") })?.level = .normal
            Task {
                let status = await ScreenCapturePermission.currentStatus()
                await MainActor.run {
                    applyCaptureStatus(status)
                    hasScreenCapture = (status == .granted)
                    updateCheck(id: "permission", granted: status == .granted)
                }
            }
        }
    }

    private func setChecking(id: String) {
        guard let idx = checks.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            checks[idx].status = .scanning
        }
        // If the real-world signal already arrived before we reached this stage,
        // resolve right after the scanning state becomes visible so user sees the
        // spinner briefly before the green tick.
        if id == "sensor" && hasAccelerometer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                updateCheck(id: "sensor", granted: true)
            }
        }
        if id == "permission" {
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                let status = await ScreenCapturePermission.currentStatus()
                await MainActor.run {
                    applyCaptureStatus(status)
                    hasScreenCapture = (status == .granted)
                    updateCheck(id: "permission", granted: status == .granted)
                }
            }
        }
    }

    private func resolve(id: String, detail: String) {
        guard let idx = checks.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            checks[idx].detail = detail
            checks[idx].status = .passed
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
    private var settingsCloseObserver: NSObjectProtocol?

    func showIfNeeded() {
        guard !KnockController.hasRequiredPermissions() else { return }
        show(title: "KnockMac Setup")
    }

    func showSettings() {
        // Close and discard existing window so a fresh OnboardingView is created.
        window?.close()
        window = nil
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        // Pause the main KnockController so its detector doesn't fire screenshots
        // while the settings wizard runs its own calibration reader on step 2.
        NotificationCenter.default.post(name: NSNotification.Name("OnboardingStarted"), object: nil)
        show(title: "KnockMac Settings", startAtStep: 0)
    }

    func closeWindow() {
        window?.close()
        // Return to accessory policy so the Dock icon disappears and the app
        // behaves as a pure menu bar utility again.
        NSApp.setActivationPolicy(.accessory)
    }

    private func show(title: String, startAtStep: Int = 0) {
        if window == nil {
            let hostingController = NSHostingController(rootView: OnboardingView(startAtStep: startAtStep))
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.title = title
            newWindow.titlebarAppearsTransparent = true
            newWindow.isMovableByWindowBackground = true
            newWindow.isReleasedWhenClosed = false
            newWindow.contentViewController = hostingController
            newWindow.level = .floating

            // Heavier rounding on the window itself to match the Liquid Glass aesthetic.
            newWindow.contentView?.wantsLayer = true
            newWindow.contentView?.layer?.cornerRadius = 20
            newWindow.contentView?.layer?.masksToBounds = true
            newWindow.backgroundColor = .clear
            newWindow.isOpaque = false
            newWindow.hasShadow = true

            newWindow.center()
            self.window = newWindow
        } else {
            window?.title = title
        }

        // LSUIElement apps relaunched after a TCC "Quit & Reopen" come up as
        // a background accessory with no Dock tile — NSApp.activate then does
        // nothing and the onboarding window stays hidden. Temporarily promote
        // to .regular so the window can take focus; closeWindow() reverts.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        DispatchQueue.main.async {
            if let window = self.window, let screen = window.screen ?? NSScreen.main {
                let screenFrame = screen.frame
                let windowFrame = window.frame
                let x = screenFrame.midX - windowFrame.width / 2
                let y = screenFrame.midY - windowFrame.height / 2
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - System check model & row view

enum CheckStatus: Equatable {
    case pending
    case scanning
    case passed
    case failed
}

struct SystemCheck: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    var detail: String? = nil
    var status: CheckStatus = .pending
    var showsGrantOnFailure: Bool = false

    static func initial() -> [SystemCheck] {
        [
            SystemCheck(id: "macos", title: "Operating System", icon: "desktopcomputer"),
            SystemCheck(id: "chip", title: "Processor", icon: "cpu"),
            SystemCheck(id: "memory", title: "Memory", icon: "memorychip"),
            SystemCheck(id: "sensor", title: "Motion Sensor", icon: "sensor.tag.radiowaves.forward"),
            SystemCheck(id: "permission", title: "Screen Recording", icon: "camera.viewfinder",
                        showsGrantOnFailure: true)
        ]
    }
}

struct SystemCheckRow: View {
    let check: SystemCheck

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: check.icon)
                .font(.system(size: 14))
                .foregroundColor(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(check.title)
                    .font(.body)
                    .foregroundColor(titleColor)
                Group {
                    if let detail = check.detail {
                        Text(detail).foregroundColor(.secondary)
                    } else if check.status == .failed && check.showsGrantOnFailure {
                        Text("Permission required").foregroundColor(.orange)
                    } else {
                        Text(" ").foregroundColor(.clear)
                    }
                }
                .font(.callout)
                .transition(.opacity)
            }

            Spacer()

            statusIndicator
                .frame(width: 18, height: 18)
        }
        .padding(.vertical, 2)
        .opacity(check.status == .pending ? 0.4 : 1.0)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch check.status {
        case .pending:
            Image(systemName: "circle.dotted")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        case .scanning:
            ProgressView()
                .scaleEffect(0.5)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.green)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(.orange)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private var iconColor: Color {
        switch check.status {
        case .pending: return .secondary
        case .scanning: return .blue
        case .passed: return .green
        case .failed: return .orange
        }
    }

    private var titleColor: Color {
        check.status == .pending ? .secondary : .primary
    }
}

// MARK: - System info readers

enum SystemInfo {
    static func osDescription() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let build = sysctlString("kern.osversion") ?? "?"
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (\(build))"
    }

    static func chipDescription() -> String {
        let brand = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let cores = sysctlInt("hw.perflevel0.physicalcpu") ?? 0
        let effCores = sysctlInt("hw.perflevel1.physicalcpu") ?? 0
        if cores > 0 && effCores > 0 {
            return "\(brand) · \(cores)P + \(effCores)E cores"
        }
        let total = sysctlInt("hw.physicalcpu") ?? 0
        return total > 0 ? "\(brand) · \(total) cores" : brand
    }

    static func memoryDescription() -> String {
        guard let bytes = sysctlUInt64("hw.memsize") else { return "Unknown" }
        let gb = Double(bytes) / 1024 / 1024 / 1024
        return String(format: "%.0f GB unified memory", gb)
    }

    static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
