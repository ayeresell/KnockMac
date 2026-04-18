import SwiftUI
import AudioToolbox
import CoreGraphics
import AppKit

// MARK: - Design tokens

private enum KM {
    static let accent       = Color(red: 10/255,  green: 132/255, blue: 255/255)
    static let success      = Color(red: 48/255,  green: 209/255, blue: 88/255)
    static let errorRed     = Color(red: 255/255, green: 69/255,  blue: 58/255)
    static let primary      = Color(red: 242/255, green: 242/255, blue: 247/255)
    static let terminalBg   = Color(red: 24/255,  green: 24/255,  blue: 28/255)

    // Terminal palette — tag tokens tinted per type, meta gets a slight teal
    // so numeric/keyword values pop against the muted label text.
    static let tagProbe     = Color(red: 254/255, green: 188/255, blue: 46/255)            // amber
    static let tagCheck     = Color(red: 255/255, green: 159/255, blue: 10/255)            // orange
    static let tagReady     = Color(red: 91/255,  green: 235/255, blue: 173/255)           // seafoam
    static let metaTint     = Color(red: 158/255, green: 220/255, blue: 224/255).opacity(0.72)
    static let caret        = Color(red: 254/255, green: 188/255, blue: 46/255).opacity(0.90)

    static func muted(_ opacity: Double) -> Color {
        Color(red: 235/255, green: 235/255, blue: 245/255).opacity(opacity)
    }

    static let mono11       = Font.system(size: 11, design: .monospaced)
    static let mono10       = Font.system(size: 10, design: .monospaced)
    static let mono13Semi   = Font.system(size: 13, weight: .semibold, design: .monospaced)
    static let mono32Bold   = Font.system(size: 32, weight: .bold, design: .monospaced)

    static func tagColor(_ tag: TerminalTag) -> Color {
        switch tag {
        case .probe: return tagProbe
        case .check: return tagCheck
        case .ready: return tagReady
        }
    }
}

// MARK: - Terminal model

enum TerminalTag: String { case probe, check, ready }

enum RowStatus: Equatable { case pending, scanning, ok, err }

struct TerminalRow: Identifiable, Equatable {
    let id: String
    let tag: TerminalTag
    let label: String
    var meta: String? = nil
    var status: RowStatus = .pending
    var visible: Bool = false
    var typed: Int = 0  // Phase A char count: idx (2) + tag (7) + label.count

    // Chars that get typed in Phase A — just the identity columns.
    var phaseAChars: Int { 2 + 7 + label.count }
    var phaseADone: Bool { typed >= phaseAChars }

    var statusText: String {
        switch status {
        case .ok:   return "OK"
        case .err:  return "ERR"
        default:    return ""
        }
    }

    // Grows once status resolves, so typed can advance past phaseAChars and
    // type meta + status one char at a time.
    var fullChars: Int { phaseAChars + (meta ?? "").count + statusText.count }

    static func initial() -> [TerminalRow] {
        [
            TerminalRow(id: "os",       tag: .probe, label: "Operating System"),
            TerminalRow(id: "cpu",      tag: .probe, label: "Processor"),
            TerminalRow(id: "mem",      tag: .probe, label: "Memory"),
            TerminalRow(id: "accel",    tag: .probe, label: "SMC accelerometer"),
            TerminalRow(id: "screen",   tag: .probe, label: "Screen recording"),
            TerminalRow(id: "disk",     tag: .probe, label: "Disk: ~/Desktop"),
            TerminalRow(id: "listener", tag: .ready, label: "Double-knock listener"),
        ]
    }
}

// MARK: - Terminal row view

struct TerminalRowView: View {
    let row: TerminalRow
    let index: Int

    var body: some View {
        let typed = row.typed

        // Phase A columns
        let idxText   = String(format: "%02d", index)
        let labelText = row.label

        let idxShown   = String(idxText.prefix(max(0, min(2, typed))))
        let labelShown = String(labelText.prefix(max(0, typed - 2)))

        // Phase B columns — meta then status, typed char-by-char.
        let pastPhaseA = max(0, typed - row.phaseAChars)
        let metaText   = row.meta ?? ""
        let metaShown  = String(metaText.prefix(min(metaText.count, pastPhaseA)))

        let pastMeta    = max(0, pastPhaseA - metaText.count)
        let statusFull  = row.statusText
        let statusShown = String(statusFull.prefix(min(statusFull.count, pastMeta)))

        let statusColor: Color = {
            switch row.status {
            case .ok:  return KM.success
            case .err: return KM.errorRed
            default:   return KM.muted(0.30)
            }
        }()

        return HStack(spacing: 10) {
            Text(idxShown)
                .foregroundColor(KM.muted(0.35))
                .frame(width: 18, alignment: .leading)

            Text(labelShown)
                .foregroundColor(KM.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(metaShown)
                .foregroundColor(KM.metaTint)
                .lineLimit(1)
                .truncationMode(.tail)

            Group {
                if row.phaseADone && (row.status == .scanning || row.status == .pending) {
                    ScanningDotsView()
                } else {
                    Text(statusShown)
                        .foregroundColor(statusColor)
                        .fontWeight(.semibold)
                }
            }
            .frame(width: 30, alignment: .trailing)
        }
        .font(KM.mono11)
        .frame(height: 19)
    }
}

struct ScanningDotsView: View {
    @State private var phase = 0
    var body: some View {
        Text(phase == 0 ? "··" : phase == 1 ? " ·" : "· ")
            .foregroundColor(KM.muted(0.30))
            .onReceive(Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()) { _ in
                phase = (phase + 1) % 3
            }
    }
}

// Reference-type buffer so the off-main HID callback can accumulate
// smoothed live-G without triggering a @State write per 100Hz sample.
private final class LiveGBuffer {
    var value: Double = 0.03
    var skip: Int = 0
}

// MARK: - OnboardingView

struct OnboardingView: View {
    var startAtStep: Int = 0

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var step = 0

    // Step 0 (System Check)
    @State private var hasScreenCapture = false
    @State private var needsCaptureRestart = false
    @State private var hasAccelerometer = false
    @State private var sysCheckReader: AccelerometerReader?
    @State private var rows: [TerminalRow] = TerminalRow.initial()
    @State private var checksStarted = false
    @State private var permissionStageStarted = false
    @State private var caretOn = true
    @State private var typingHead: Int = 0
    @State private var promptTyped: Int = 0
    @State private var screenModalFired: Bool = false

    // Step 2 (Test it out)
    @State private var verifyKnockCount: Int = 0
    @State private var liveG: Double = 0.03
    @State private var calibrationReader: AccelerometerReader?
    @State private var calibrationDetector: KnockDetector?
    @State private var calibrationStarted = false
    @State private var liveGBuffer = LiveGBuffer()

    var body: some View {
        VStack(spacing: 0) {
            if step == 0 {
                systemCheckScreen
            } else if step == 1 {
                whereToKnockScreen
            } else if step == 2 {
                testItOutScreen
            }
        }
        .frame(width: 460, height: 480)
        .background(.thickMaterial)
        .preferredColorScheme(.dark)
        .onAppear {
            if startAtStep > 0 { step = startAtStep }
        }
        .onDisappear {
            stopCalibration()
            sysCheckReader?.stop()
        }
    }

    // MARK: Step 0 — System Check

    private var systemCheckScreen: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("System Check")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.5)
                    .foregroundColor(KM.primary)

                Text("Live diagnostic. Each line is re-verified every launch.")
                    .font(.system(size: 13))
                    .foregroundColor(KM.muted(0.60))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            terminalPanel
                .frame(maxHeight: .infinity)

            terminalFooter
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .transition(.opacity)
        .onAppear {
            if !checksStarted {
                checksStarted = true
                runSystemCheck()
                runAnimatedDiagnostic()
                if !rows.isEmpty {
                    rows[0].visible = true
                    if rows[0].status == .pending { rows[0].status = .scanning }
                }
            }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            caretOn.toggle()
        }
        .onReceive(Timer.publish(every: 0.035, on: .main, in: .common).autoconnect()) { _ in
            advanceTyping()
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            if permissionStageStarted && !hasScreenCapture {
                refreshScreenCaptureAccess()
            }
        }
        .onChange(of: hasScreenCapture) { _, granted in
            let meta = granted
                ? "granted"
                : (needsCaptureRestart ? "restart required" : "permission required")
            updateRow(id: "screen", granted: granted, meta: meta)
            if granted {
                NSApp.windows.first(where: { $0.title.hasPrefix("KnockMac") })?.level = .floating
            }
        }
        .onChange(of: hasAccelerometer) { _, ok in
            updateRow(id: "accel", granted: ok, meta: ok ? "@ 100 Hz" : "not found")
        }
    }

    private var terminalPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                TerminalRowView(row: row, index: idx + 1)
                    .opacity(row.visible ? 1 : 0)
            }

            HStack(spacing: 10) {
                Text("—")
                    .foregroundColor(KM.muted(0.40))
                    .frame(width: 18, alignment: .leading)
                HStack(spacing: 4) {
                    Text(String(promptMessage.prefix(promptTyped)))
                        .foregroundColor(KM.muted(0.55))
                    Rectangle()
                        .fill(KM.caret)
                        .frame(width: 7, height: 12)
                        .opacity(caretOn ? 1 : 0)
                }
                Spacer()
            }
            .font(KM.mono11)
            .frame(height: 19)
            .padding(.top, 6)
            .opacity(allResolved ? 1 : 0)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(KM.terminalBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var terminalFooter: some View {
        HStack {
            Button(action: copyLog) {
                Text("Copy log")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(KM.muted(0.75))
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Spacer()

            if allFullyTyped {
                if allPassed {
                    Button("Continue") {
                        withAnimation { step = 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .transition(.opacity.combined(with: .scale))
                } else if needsCaptureRestart {
                    Button("Quit & Reopen") {
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
        }
    }

    // MARK: Step 1 — Where to knock (unchanged)

    private var whereToKnockScreen: some View {
        VStack(spacing: 20) {
            Text("Where to knock")
                .font(.title)
                .fontWeight(.bold)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 300, height: 200)
                    .shadow(radius: 5)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 260, height: 90)
                    .offset(y: -10)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 100, height: 60)
                    .offset(y: 70)

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
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
        }
        .padding(.top, 30)
        .padding(.horizontal, 30)
        .padding(.bottom, 30)
        .transition(.opacity)
    }

    // MARK: Step 2 — Test it out

    private var testItOutScreen: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("Test it out")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.5)
                    .foregroundColor(KM.primary)
                Text("Three knocks. Each fills one ring.")
                    .font(.system(size: 13))
                    .foregroundColor(KM.muted(0.60))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            Spacer(minLength: 0)

            ringStack

            Spacer(minLength: 0)

            chipsRow

            HStack {
                Button("Back") {
                    verifyKnockCount = 0
                    stopCalibration()
                    calibrationStarted = false
                    withAnimation { step = 1 }
                }
                .buttonStyle(.plain)
                .foregroundColor(KM.muted(0.75))
                .font(.system(size: 13, weight: .semibold))
                .padding(.vertical, 6)

                Spacer()

                Button(verifyKnockCount >= 3 ? "Finish" : "Waiting…") {
                    finishOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .disabled(verifyKnockCount < 3)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .transition(.opacity)
        .onAppear {
            if !calibrationStarted {
                calibrationStarted = true
                startVerificationCalibration()
            }
        }
    }

    private var ringStack: some View {
        let size: CGFloat = 172
        let stroke: CGFloat = 7
        let radii: [CGFloat] = [73, 59, 45]
        let done = verifyKnockCount >= 3

        return ZStack {
            ForEach(radii.indices, id: \.self) { i in
                let radius = radii[i]
                let filled = verifyKnockCount > i

                Circle()
                    .stroke(Color.white.opacity(0.07), lineWidth: stroke)
                    .frame(width: radius * 2, height: radius * 2)

                Circle()
                    .trim(from: 0, to: filled ? 1 : 0)
                    .stroke(
                        done ? KM.success : KM.accent,
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: radius * 2, height: radius * 2)
                    .animation(.easeOut(duration: 0.26), value: verifyKnockCount)
            }

            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(verifyKnockCount)")
                        .font(KM.mono32Bold)
                        .foregroundColor(done ? KM.success : KM.primary)
                    Text("/3")
                        .font(KM.mono32Bold)
                        .foregroundColor(KM.muted(0.30))
                }
                Text(String(format: "%.3f g", liveG))
                    .font(KM.mono10)
                    .tracking(0.5)
                    .foregroundColor(KM.muted(0.50))
                    .padding(.top, 2)
            }
        }
        .frame(width: size, height: size)
    }

    private var chipsRow: some View {
        HStack(spacing: 8) {
            ForEach(0..<3) { i in
                let detected = verifyKnockCount > i
                VStack(alignment: .leading, spacing: 2) {
                    Text("KNOCK \(i + 1)")
                        .font(KM.mono10)
                        .tracking(0.5)
                        .foregroundColor(KM.muted(0.45))
                    Text(detected ? "● detected" : "○ waiting")
                        .font(KM.mono13Semi)
                        .foregroundColor(detected ? KM.accent : KM.muted(0.40))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(detected ? KM.accent.opacity(0.12) : Color.white.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(detected ? KM.accent.opacity(0.40) : Color.white.opacity(0.06), lineWidth: 0.5)
                )
                .animation(.easeOut(duration: 0.20), value: detected)
            }
        }
    }

    // MARK: Computed

    private var allResolved: Bool {
        rows.allSatisfy { $0.status == .ok || $0.status == .err }
    }
    private var allPassed: Bool {
        rows.allSatisfy { $0.status == .ok }
    }
    private var hasPermissionFailure: Bool {
        rows.contains(where: { $0.id == "screen" && $0.status == .err })
    }
    // True only once every row has fully typed through meta + status. Used to
    // gate the footer buttons so they never surface while the terminal is
    // still animating.
    private var allFullyTyped: Bool {
        typingHead >= rows.count && rows.allSatisfy { $0.typed >= $0.fullChars }
    }
    private var promptMessage: String {
        if allPassed { return "Ready. Waiting for input." }
        if allResolved { return "Attention required." }
        return "Running diagnostic…"
    }

    // MARK: Screen-capture plumbing

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

    private func requestScreenRecordingAccess() {
        NSApp.windows.first(where: { $0.title.hasPrefix("KnockMac") })?.level = .normal
        // Registers the bundle in TCC so it appears in the Screen Recording list.
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
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

    // MARK: Row mutation

    private func revealRow(id: String) {
        guard let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            rows[idx].visible = true
            if rows[idx].status == .pending {
                rows[idx].status = .scanning
            }
        }
    }

    private func updateRow(id: String, granted: Bool, meta: String? = nil) {
        guard let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        // Probes may fire before typewriter reveals the row (e.g. the IMU
        // delivers its first sample at ~10ms while row 4 reveals at ~1.7s).
        // Allow writing the result regardless of current status — the view
        // only surfaces it once phaseA has been typed.
        withAnimation(.easeOut(duration: 0.25)) {
            rows[idx].status = granted ? .ok : .err
            if let meta = meta { rows[idx].meta = meta }
        }
        maybeArmListener()
    }

    private func resolveRow(id: String, granted: Bool, meta: String) {
        guard let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            rows[idx].status = granted ? .ok : .err
            rows[idx].meta = meta
        }
        maybeArmListener()
    }

    private func maybeArmListener() {
        let keys = ["os", "cpu", "mem", "accel", "screen", "disk"]
        let prereqs = keys.compactMap { id in rows.first(where: { $0.id == id }) }
        guard prereqs.count == keys.count else { return }
        let allOK = prereqs.allSatisfy { $0.status == .ok }
        let fullyResolved = prereqs.allSatisfy { $0.status == .ok || $0.status == .err }
        // Wait until the prereq rows have fully typed out their meta+status
        // (Phase B) — otherwise "armed OK" prints in parallel with (and often
        // finishes before) the row above, which breaks the top-to-bottom feel.
        let allTyped = prereqs.allSatisfy { $0.typed >= $0.fullChars }
        guard allTyped else { return }
        guard let idx = rows.firstIndex(where: { $0.id == "listener" }) else { return }
        guard rows[idx].status == .scanning || rows[idx].status == .pending else { return }
        if allOK {
            withAnimation(.easeOut(duration: 0.25)) {
                rows[idx].status = .ok
                rows[idx].meta = "armed"
            }
        } else if fullyResolved {
            withAnimation(.easeOut(duration: 0.25)) {
                rows[idx].status = .err
                rows[idx].meta = "blocked"
            }
        }
    }

    private func copyLog() {
        var lines: [String] = ["KnockMac — System Check"]
        for (i, r) in rows.enumerated() {
            let tag = "[\(r.tag.rawValue)]".padding(toLength: 8, withPad: " ", startingAt: 0)
            let label = r.label.padding(toLength: 26, withPad: " ", startingAt: 0)
            let meta = (r.meta ?? "").padding(toLength: 24, withPad: " ", startingAt: 0)
            let status: String
            switch r.status {
            case .ok: status = "OK"
            case .err: status = "ERR"
            case .scanning, .pending: status = "..."
            }
            lines.append(String(format: "%02d %@ %@ %@ %@", i + 1, tag, label, meta, status))
        }
        lines.append("— \(promptMessage)")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: Diagnostic sequence

    private func advanceTyping() {
        // Phase A — strictly serial: one row at a time. Reveals the next row
        // only when the current row has finished typing idx/tag/label.
        if typingHead < rows.count {
            if rows[typingHead].visible {
                if rows[typingHead].typed < rows[typingHead].phaseAChars {
                    rows[typingHead].typed += 1
                } else {
                    typingHead += 1
                    if typingHead < rows.count {
                        rows[typingHead].visible = true
                        if rows[typingHead].status == .pending {
                            rows[typingHead].status = .scanning
                        }
                    }
                }
            }
        }

        // Phase B — meta + status chars. Runs in parallel across all rows
        // that are past Phase A and have a resolved status, so a slow probe
        // on row N doesn't block typing on row N+1.
        for i in 0..<rows.count {
            let row = rows[i]
            guard row.typed >= row.phaseAChars else { continue }
            guard row.typed < row.fullChars else { continue }
            if row.status == .ok || row.status == .err {
                rows[i].typed += 1
            }
        }

        // Re-check the listener gate each tick — it waits for all prereqs to
        // finish their Phase B typing, so it can't arm until they're visually
        // done.
        maybeArmListener()

        // Prompt line — typed only after the whole table is settled.
        if typingHead >= rows.count && allResolved && promptTyped < promptMessage.count {
            promptTyped += 1
        }

        // TCC modal is deferred until the terminal has completely finished
        // animating — status + ERR + listener "blocked" are all typed out
        // before the system prompt surfaces. Skipped when access is already
        // granted, or when only a relaunch can recover (user uses the
        // "Quit & Reopen" button instead).
        if allFullyTyped
            && !screenModalFired
            && !hasScreenCapture
            && !needsCaptureRestart
        {
            screenModalFired = true
            fireScreenRecordingModal()
        }
    }

    private func runAnimatedDiagnostic() {
        // Synchronous probes — resolve after brief scan visible window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            resolveRow(id: "os", granted: true, meta: SystemInfo.osDescription())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            resolveRow(id: "cpu", granted: true, meta: SystemInfo.chipDescription())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
            resolveRow(id: "mem", granted: true, meta: SystemInfo.memoryDescription())
        }

        // Accelerometer — resolves via onChange(hasAccelerometer). Fallback after 4.5 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            if let idx = rows.firstIndex(where: { $0.id == "accel" }),
               rows[idx].status == .scanning {
                updateRow(id: "accel", granted: false, meta: "not found")
            }
        }

        // Screen recording — safe preflight. Doesn't surface the TCC modal;
        // that's deferred to fireScreenRecordingModal() which runs only after
        // the whole terminal has finished typing (see advanceTyping).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            probeScreenRecording()
        }

        // Disk — probe writable state of ~/Desktop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.55) {
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            let writable = desktop.map { FileManager.default.isWritableFile(atPath: $0.path) } ?? false
            resolveRow(id: "disk", granted: writable, meta: writable ? "writable" : "not writable")
        }
    }

    // Synchronous TCC-state probe. CGPreflightScreenCaptureAccess returns the
    // cached TCC entry without prompting — comparing it to launchTimeGranted
    // also catches the "user toggled since launch" case that requires a
    // relaunch.
    private func probeScreenRecording() {
        let preflight = CGPreflightScreenCaptureAccess()
        let launch = ScreenCapturePermission.launchTimeGranted
        let restartNeeded = (preflight != launch)
        let granted = preflight && !restartNeeded
        needsCaptureRestart = restartNeeded
        hasScreenCapture = granted
        if restartNeeded {
            UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
            UserDefaults.standard.synchronize()
        }
        let meta = granted
            ? "granted"
            : (restartNeeded ? "restart required" : "permission required")
        updateRow(id: "screen", granted: granted, meta: meta)
    }

    // Surfaces the actual macOS TCC modal. Called only after the terminal
    // finishes typing so the prompt never races with the scanning animation.
    // No-op if access is already granted, or the user just needs to relaunch
    // (in that case the "Quit & Reopen" button is the recovery path).
    private func fireScreenRecordingModal() {
        permissionStageStarted = true
        NSApp.windows.first(where: { $0.title.hasPrefix("KnockMac") })?.level = .normal
        _ = CGRequestScreenCaptureAccess()
    }

    // MARK: Verification calibration

    private func startVerificationCalibration() {
        stopCalibration()
        verifyKnockCount = 0
        liveG = 0.03
        liveGBuffer.value = 0.03
        liveGBuffer.skip = 0

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

        let buffer = self.liveGBuffer
        reader.onSample = { sample in
            detector.feed(sample)
            let mag = abs(sample.magnitude - 1.0)
            buffer.value = buffer.value * 0.88 + mag * 0.12
            buffer.skip += 1
            if buffer.skip >= 4 {
                buffer.skip = 0
                let v = buffer.value
                DispatchQueue.main.async {
                    self.liveG = v
                }
            }
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

// MARK: - Window manager

@MainActor
class OnboardingWindowManager {
    static let shared = OnboardingWindowManager()
    private var window: NSWindow?
    private var settingsCloseObserver: NSObjectProtocol?

    func showIfNeeded() {
        guard !KnockController.hasRequiredPermissions() else { return }
        // Clear the completion flag so any subsequent relaunch (ours or
        // macOS's auto Quit & Reopen after a TCC grant) re-surfaces the
        // wizard instead of just showing the menu bar icon silently.
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
        UserDefaults.standard.synchronize()
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
        // If the user closes the settings window without clicking Finish,
        // resume the main controller so knock detection doesn't stay disabled.
        if let settingsWindow = window {
            if let prior = settingsCloseObserver {
                NotificationCenter.default.removeObserver(prior)
            }
            settingsCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: settingsWindow,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    NotificationCenter.default.post(name: NSNotification.Name("OnboardingCompleted"), object: nil)
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
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
            // Force dark so the terminal panel and tokens render consistently
            // regardless of the user's system appearance.
            newWindow.appearance = NSAppearance(named: .darkAqua)

            // Heavier rounding on the window itself to match the Liquid Glass aesthetic.
            newWindow.contentView?.wantsLayer = true
            newWindow.contentView?.layer?.cornerRadius = 20
            newWindow.contentView?.layer?.masksToBounds = true
            newWindow.backgroundColor = .clear
            newWindow.isOpaque = false
            newWindow.hasShadow = true

            self.window = newWindow
        } else {
            window?.title = title
        }

        // Center synchronously *before* makeKeyAndOrderFront so the window
        // never appears at an off-centre position. `NSWindow.center()`
        // biases upward (Apple's "visually pleasing" placement) which
        // caused a visible jump to true centre after show.
        if let window, let screen = NSScreen.main {
            let sf = screen.frame
            let wf = window.frame
            window.setFrameOrigin(NSPoint(
                x: sf.midX - wf.width / 2,
                y: sf.midY - wf.height / 2
            ))
        }

        // LSUIElement apps relaunched after a TCC "Quit & Reopen" come up as
        // a background accessory with no Dock tile — NSApp.activate then does
        // nothing and the onboarding window stays hidden. Temporarily promote
        // to .regular so the window can take focus; closeWindow() reverts.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
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
            return "\(brand) · \(cores)P+\(effCores)E"
        }
        let total = sysctlInt("hw.physicalcpu") ?? 0
        return total > 0 ? "\(brand) · \(total) cores" : brand
    }

    static func memoryDescription() -> String {
        guard let bytes = sysctlUInt64("hw.memsize") else { return "Unknown" }
        let gb = Double(bytes) / 1024 / 1024 / 1024
        return String(format: "%.0f GB unified", gb)
    }

    static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
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
