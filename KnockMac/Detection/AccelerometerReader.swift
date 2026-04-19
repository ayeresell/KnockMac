import Foundation

// Reads accelerometer data on Apple Silicon Macs via the IOHIDEventSystemClient
// path (private API, exposed through IMUEventReader.m bridge).
//
// On macOS 26.4+ the public IOHIDDevice + InputReportCallback path no longer
// receives input reports for the SPU IMU even after IOHIDDeviceOpen succeeds.
// The IOHIDEventSystemClient path is the only one that delivers events, and
// requires a "kick" via SetProperty on the IOHIDServiceClient to wake the
// SPU streaming pipeline. See IMUEventReader.m for the bridge.
//
// Events arrive at ~140 Hz with x/y/z already in units of g.

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

    nonisolated(unsafe) private var reader: IMUEventReaderRef?
    nonisolated(unsafe) private var retainedSelf: Unmanaged<AccelerometerReader>?

    // MARK: Lifecycle

    init() {
        start()
    }

    deinit {
        if let reader { IMUEventReaderDestroy(reader) }
        retainedSelf?.release()
    }

    // MARK: Control

    /// Re-establishes streaming. Used after onboarding's calibration reader
    /// finishes — preserves the API contract from the IOHIDDevice-era reader.
    func rebind() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.start()
        }
    }

    func stop() {
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
            // Safe to assume MainActor isolation.
            let reader = Unmanaged<AccelerometerReader>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated {
                reader.handleSample(x: x, y: y, z: z)
            }
        }, retained.toOpaque())

        if reader != nil {
            print("[Accel] IMU streaming started (Event System path)")
        } else {
            retained.release()
            retainedSelf = nil
            print("[Accel] IMUEventReaderCreate failed — IMU service not found or kick rejected")
        }
    }

    private func handleSample(x: Double, y: Double, z: Double) {
        if !isAvailable { isAvailable = true }
        onSample?(AccelSample(x: x, y: y, z: z))
    }
}
