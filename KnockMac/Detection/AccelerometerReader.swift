import Foundation
import IOKit
import IOKit.hid

// Reads raw accelerometer data from the Apple Silicon SPU IMU (Bosch BMI286).
// Device: vendor 0x05AC, product 0x8104, usagePage 0xFF00, usage 0x03
// Reports: 22 bytes, XYZ as Int32 LE at offsets 6 / 10 / 14, scale ÷ 65536 → g
//
// Architecture mirrors taigrr/spank (Go) and olvvier/apple-silicon-accelerometer.

struct AccelSample {
    let x: Double
    let y: Double
    let z: Double

    var magnitude: Double { (x*x + y*y + z*z).squareRoot() }
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
    nonisolated(unsafe) private var reportBuffer = [UInt8](repeating: 0, count: 64)
    nonisolated(unsafe) private static let noOptions = IOOptionBits(kIOHIDOptionsTypeNone)

    // MARK: Lifecycle

    init() {
        setupManager()
    }

    deinit {
        if let dev = device {
            IOHIDDeviceClose(dev, Self.noOptions)
        }
        if let mgr = manager {
            IOHIDManagerClose(mgr, Self.noOptions)
        }
    }

    // MARK: Control

    func stop() {
        guard let dev = device else { return }
        IOHIDDeviceClose(dev, Self.noOptions)
        device = nil
        isAvailable = false
    }

    // MARK: Setup

    private func setupManager() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, Self.noOptions)
        let matching: [String: Any] = [
            kIOHIDVendorIDKey  as String:       0x05AC,
            kIOHIDProductIDKey as String:       0x8104,
            kIOHIDDeviceUsagePageKey as String: 0xFF00,
            kIOHIDDeviceUsageKey as String:     0x03,
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, Self.noOptions)
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
        let openResult = IOHIDDeviceOpen(dev, Self.noOptions)
        guard openResult == kIOReturnSuccess else {
            print("[Accel] Failed to open device: 0x\(String(openResult, radix: 16))")
            return
        }
        let reportSize = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        print("[Accel] Device opened — reportSize=\(reportSize)b")
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        IOHIDDeviceRegisterInputReportCallback(
            dev, &reportBuffer, CFIndex(reportBuffer.count),
            { ctx, _, _, _, _, report, length in
                guard let ctx, length >= 18 else { return }
                // Callback fires on the main run loop — safe to assume MainActor
                let reader = Unmanaged<AccelerometerReader>.fromOpaque(ctx).takeUnretainedValue()
                MainActor.assumeIsolated {
                    reader.handleReport(report, length: length)
                }
            },
            Unmanaged.passUnretained(self).toOpaque()
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
