import Foundation
import IOKit
import IOKit.hid

// Reads raw accelerometer data from the Apple Silicon SPU IMU (Bosch BMI286).
// Device: vendor 0x05AC, product 0x8104, usagePage 0xFF00, usage 0x03
// Reports: 22 bytes, XYZ as Int32 LE at offsets 6 / 10 / 14, scale ÷ 65536 → g
//
// Architecture mirrors taigrr/spank (Go) and olvvier/apple-silicon-accelerometer.

private let kHIDNoOptions = IOOptionBits(kIOHIDOptionsTypeNone)

struct AccelSample {
    let x: Double
    let y: Double
    let z: Double
    // Pre-computed once on creation — magnitude is accessed by every detection algorithm.
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
    // nonisolated(unsafe) — accessed from the C HID callback (not on main actor)

    nonisolated(unsafe) private var manager: IOHIDManager?
    nonisolated(unsafe) private var device: IOHIDDevice?

    // Fixed-size buffer allocated once — safe to pass as IOKit-owned storage.
    // Swift Array is not safe here: COW can invalidate the internal pointer mid-write.
    nonisolated(unsafe) private let reportBufferPtr: UnsafeMutablePointer<UInt8> = .allocate(capacity: 64)
    private let reportBufferSize = 64


    // Retained reference passed into the C callback to guarantee self outlives it.
    nonisolated(unsafe) private var retainedSelf: Unmanaged<AccelerometerReader>?

    // MARK: Lifecycle

    init() {
        setupManager()
    }

    deinit {
        // Release the retained reference taken in openDevice, then free the buffer.
        retainedSelf?.release()
        retainedSelf = nil
        reportBufferPtr.deallocate()

        if let dev = device {
            IOHIDDeviceClose(dev, kHIDNoOptions)
        }
        if let mgr = manager {
            IOHIDManagerClose(mgr, kHIDNoOptions)
        }
    }

    // MARK: Control

    /// Re-opens and re-registers the HID callback.
    /// Call this whenever another reader may have stolen the device callback (e.g. after calibration).
    func rebind() {
        if let dev = device {
            IOHIDDeviceRegisterInputReportCallback(dev, reportBufferPtr, CFIndex(reportBufferSize), nil, nil)
            IOHIDDeviceClose(dev, kHIDNoOptions)
            device = nil
            isAvailable = false
            retainedSelf?.release()
            retainedSelf = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.bindDevice()
        }
    }

    func stop() {
        guard let dev = device else { return }
        // Deregister callback before closing to prevent callbacks firing into freed memory.
        IOHIDDeviceRegisterInputReportCallback(dev, reportBufferPtr, CFIndex(reportBufferSize), nil, nil)
        IOHIDDeviceClose(dev, kHIDNoOptions)
        device = nil
        isAvailable = false

        // Release the retained self reference now that the callback is unregistered.
        retainedSelf?.release()
        retainedSelf = nil
    }

    // MARK: Setup

    private func setupManager() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, kHIDNoOptions)
        let matching: [String: Any] = [
            kIOHIDVendorIDKey  as String:       0x05AC,
            kIOHIDProductIDKey as String:       0x8104,
            kIOHIDDeviceUsagePageKey as String: 0xFF00,
            kIOHIDDeviceUsageKey as String:     0x03,
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, kHIDNoOptions)
        self.manager = mgr

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.bindDevice()
        }
    }

    private func bindDevice() {
        guard let mgr = manager,
              let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>
        else { return }

        // Prefer the 22-byte report device (the actual IMU)
        let dev: IOHIDDevice? = set.first(where: {
            (IOHIDDeviceGetProperty($0, kIOHIDMaxInputReportSizeKey as CFString) as? Int) == 22
        }) ?? set.first

        guard let dev else { return }
        openDevice(dev)
    }

    private func openDevice(_ dev: IOHIDDevice) {
        let openResult = IOHIDDeviceOpen(dev, kHIDNoOptions)
        guard openResult == kIOReturnSuccess else {
            print("[Accel] Failed to open device: 0x\(String(openResult, radix: 16))")
            return
        }
        let reportSize = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        print("[Accel] Device opened — reportSize=\(reportSize)b")
        // macOS 26+: IMU no longer auto-streams input reports after open. Explicitly
        // request a 10ms report interval (100 Hz) to kick the SPU pipeline on. The
        // device may still stream at its native rate (125 Hz / 8ms) — this is a hint.
        IOHIDDeviceSetProperty(dev, kIOHIDReportIntervalKey as CFString, 10_000 as CFNumber)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        // Retain self for the C callback lifetime.
        // Balanced by release() in stop() or deinit.
        let retained = Unmanaged.passRetained(self)
        self.retainedSelf = retained

        IOHIDDeviceRegisterInputReportCallback(
            dev, reportBufferPtr, CFIndex(reportBufferSize),
            { ctx, _, _, _, _, report, length in
                guard let ctx, length >= 18 else { return }
                // Callback fires on the main run loop — safe to assume MainActor.
                let reader = Unmanaged<AccelerometerReader>.fromOpaque(ctx).takeUnretainedValue()
                MainActor.assumeIsolated {
                    reader.handleReport(report, length: length)
                }
            },
            retained.toOpaque()
        )

        device = dev
        isAvailable = true
        print("[Accel] Ready — listening for reports")
    }

    // MARK: Report Parsing

    private func handleReport(_ report: UnsafePointer<UInt8>, length: CFIndex) {
        func int32(at offset: Int) -> Int32 {
            var v: Int32 = 0
            withUnsafeMutableBytes(of: &v) {
                $0.copyBytes(from: UnsafeRawBufferPointer(start: report.advanced(by: offset), count: 4))
            }
            return v
        }

        let sample = AccelSample(
            x: Double(int32(at: 6))  / 65536.0,
            y: Double(int32(at: 10)) / 65536.0,
            z: Double(int32(at: 14)) / 65536.0
        )

        onSample?(sample)
    }
}
