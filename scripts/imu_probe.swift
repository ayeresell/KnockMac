// Minimal IMU reader. Compile & run:
//   swiftc /Users/anton/Desktop/Xcode/KnockMac/scripts/imu_probe.swift -o /tmp/imu_probe
//   /tmp/imu_probe
//
// Opens the Apple Silicon IMU (vendor 0x05AC, product 0x8104, usagePage 0xFF00, usage 0x03)
// and prints any input report it receives. Runs for 10 seconds then exits.
//
// If this prints "Report #1 ..." — hardware is streaming and the bug is in our app.
// If it prints "Device opened" but never any "Report #" line — hardware/firmware issue,
// no user-space client on this boot can read IMU.

import Foundation
import IOKit
import IOKit.hid

let runSeconds: TimeInterval = 10
let matching: [String: Any] = [
    kIOHIDVendorIDKey  as String:       0x05AC,
    kIOHIDProductIDKey as String:       0x8104,
    kIOHIDDeviceUsagePageKey as String: 0xFF00,
    kIOHIDDeviceUsageKey as String:     0x03,
]

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let openManagerResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
print("[probe] IOHIDManagerOpen result=0x\(String(openManagerResult, radix: 16))")

guard let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !devices.isEmpty else {
    print("[probe] No matching devices found. Exiting.")
    exit(1)
}
print("[probe] Matched \(devices.count) device(s)")

// Prefer the 22-byte device (our IMU report)
let dev = devices.first(where: {
    (IOHIDDeviceGetProperty($0, kIOHIDMaxInputReportSizeKey as CFString) as? Int) == 22
}) ?? devices.first!

let reportSize = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
let usagePage = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
let usage = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
print("[probe] Picked device: usagePage=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16)) reportSize=\(reportSize)b")

// Try Seize first — exclusive lock on the device. Sometimes kicks the streaming
// pipeline when a passive open doesn't.
let seizeResult = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
print("[probe] IOHIDDeviceOpen (seize) result=0x\(String(seizeResult, radix: 16))")
let openResult: IOReturn
if seizeResult == kIOReturnSuccess {
    openResult = seizeResult
} else {
    openResult = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
    print("[probe] IOHIDDeviceOpen (none) result=0x\(String(openResult, radix: 16))")
}
guard openResult == kIOReturnSuccess else {
    print("[probe] All open attempts failed")
    exit(1)
}

// Try to kick streaming (in case driver needs an explicit hint)
let preInterval = IOHIDDeviceGetProperty(dev, kIOHIDReportIntervalKey as CFString) as? Int ?? -1
let setOK = IOHIDDeviceSetProperty(dev, kIOHIDReportIntervalKey as CFString, 8000 as CFNumber)
let postInterval = IOHIDDeviceGetProperty(dev, kIOHIDReportIntervalKey as CFString) as? Int ?? -1
print("[probe] ReportInterval before=\(preInterval) setOK=\(setOK) after=\(postInterval)")

IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

let bufSize = 64
let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
var reportCount = 0

IOHIDDeviceRegisterInputReportCallback(
    dev, buf, CFIndex(bufSize),
    { _, result, _, _, reportID, report, length in
        reportCount += 1
        if reportCount <= 3 || reportCount % 100 == 0 {
            // Decode xyz like the app does
            func i32(at offset: Int) -> Int32 {
                var v: Int32 = 0
                withUnsafeMutableBytes(of: &v) {
                    $0.copyBytes(from: UnsafeRawBufferPointer(start: report.advanced(by: offset), count: 4))
                }
                return v
            }
            if length >= 18 {
                let x = Double(i32(at: 6))  / 65536.0
                let y = Double(i32(at: 10)) / 65536.0
                let z = Double(i32(at: 14)) / 65536.0
                print(String(format: "[probe] Report #%d result=0x%x reportID=%d length=%ld x=%.3f y=%.3f z=%.3f",
                             reportCount, result, reportID, length, x, y, z))
            } else {
                print("[probe] Report #\(reportCount) result=0x\(String(result, radix: 16)) reportID=\(reportID) length=\(length) (short)")
            }
        }
    },
    nil
)

// Also register element value callback as a secondary diagnostic
IOHIDDeviceRegisterInputValueCallback(
    dev,
    { _, _, _, _ in
        print("[probe] InputValue callback fired (element-level)")
    },
    nil
)

print("[probe] Listening for \(Int(runSeconds))s...")

// Exit after N seconds with a summary
DispatchQueue.main.asyncAfter(deadline: .now() + runSeconds) {
    print("[probe] === Summary: \(reportCount) report(s) received in \(Int(runSeconds))s ===")
    IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    exit(0)
}

RunLoop.main.run()
