import Foundation

// Reads accelerometer data on Apple Silicon Macs via the IOHIDEventSystemClient
// path (private API, exposed through IMUEventReader.m bridge).
//
// On macOS 26.4+ the public IOHIDDevice + InputReportCallback path no longer
// receives input reports for the SPU IMU. The Event System path is the only
// one that delivers events, and requires a "kick" via SetProperty on the
// IOHIDServiceClient to wake the SPU streaming pipeline. See IMUEventReader.m.
//
// Events arrive at ~140 Hz with x/y/z already in units of g.
//
// LIFETIME: `start()` retains self (Unmanaged.passRetained) so the C callback
// can safely dereference the opaque context. `stop()` balances the release.
// Callers MUST call `stop()` before the last strong reference is dropped —
// otherwise deinit never fires.

struct AccelSample {
    let x: Double
    let y: Double
    let z: Double
    let magnitude: Double

    init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.magnitude = (x*x + y*y + z*z).squareRoot()
    }
}

@MainActor
final class AccelerometerReader {

    // MARK: Public

    var onSample: ((AccelSample) -> Void)?
    private(set) var isAvailable = false

    // MARK: Private

    private var reader: IMUEventReaderRef?
    private var retainedSelf: Unmanaged<AccelerometerReader>?
    // Invalidates pending rebind() closures so a mid-flight stop() can cancel
    // an impending restart (otherwise dispatch_after would resurrect the reader
    // after the caller asked us to stop).
    private var rebindGeneration: UInt64 = 0

    // MARK: Lifecycle

    init() {
        start()
    }

    // MARK: Control

    /// Stop and restart streaming after a brief settling delay. Used by
    /// KnockController after onboarding's calibration reader exits, so that
    /// any pipeline state the calibration reader might have perturbed is
    /// re-established cleanly.
    func rebind() {
        stop()
        let gen = rebindGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.rebindGeneration == gen else { return }
            self.start()
        }
    }

    func stop() {
        rebindGeneration &+= 1
        guard let r = reader else { return }
        IMUEventReaderDestroy(r)
        reader = nil
        retainedSelf?.release()
        retainedSelf = nil
        isAvailable = false
    }

    // MARK: Setup

    private func start() {
        guard reader == nil else { return }

        let retained = Unmanaged.passRetained(self)
        retainedSelf = retained

        reader = IMUEventReaderCreate({ x, y, z, ctx in
            guard let ctx else { return }
            // Callback fires on the main dispatch queue (set in IMUEventReader.m).
            let reader = Unmanaged<AccelerometerReader>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated {
                reader.handleSample(x: x, y: y, z: z)
            }
        }, retained.toOpaque())

        if reader == nil {
            retained.release()
            retainedSelf = nil
            print("[Accel] IMUEventReaderCreate failed — IMU service not found or kick rejected")
        } else {
            print("[Accel] IMU streaming started (Event System path)")
        }
    }

    private func handleSample(x: Double, y: Double, z: Double) {
        if !isAvailable { isAvailable = true }
        onSample?(AccelSample(x: x, y: y, z: z))
    }
}
