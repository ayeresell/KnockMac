# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## About

KnockMac is a macOS menu bar app that lets users take screenshots by double-knocking on the laptop body. It reads raw IMU data from the Apple Silicon accelerometer via IOKit HID, detects a double-knock pattern using a 5-algorithm voting system, and captures the screen via ScreenCaptureKit.

- Runs as a menu bar app only (`LSUIElement = true`) — no Dock icon
- Requires macOS 14.0+, Apple Silicon (IMU access), Screen Recording permission
- First launch shows a calibration wizard that tunes sensitivity and knock speed to the user
- Screenshots saved to `~/Desktop/KnockMac-<timestamp>.png`

## Build & Run

```bash
# Generate Xcode project from project.yml (requires XcodeGen)
xcodegen generate

# Build from command line
xcodebuild -project KnockMac.xcodeproj -scheme KnockMac -configuration Debug build

# Reset onboarding in DEBUG builds (pass as launch argument in Xcode scheme)
--reset-onboarding
```

## Architecture

**Entry point:** `KnockMacApp` → creates `KnockController` as `@StateObject`, shows `MenuBarExtra`. Single-instance guard and `OnboardingWindowManager.shared.showIfNeeded()` run in `onAppear`.

**Data flow:**
```
AccelerometerReader (IOHIDManager → Apple Silicon IMU, vendor 0x05AC / product 0x8104)
    ↓ AccelSample (x, y, z in g, ~100 Hz)
KnockController (checks LidAngleSensor.isOpen before forwarding)
    ↓
KnockDetector.feed()
    → 5-algorithm voting system (need ≥3/5 votes to register a knock)
    → double-knock: two votes within minGap(0.08s)…maxGap(configurable, default 0.45s)
    → cooldown: 1.0s between triggers
    ↓
KnockController.handleKnock()
    → AudioPlayer.playKnockSound() (system sound 1108)
    → ScreenshotAction.captureFullScreen() (ScreenCaptureKit → PNG on Desktop)
```

**Detection algorithms** (`KnockDetector.swift`): `MagnitudeThreshold`, `Jerk`, `Energy`, `ZAxisDominance`, `PeakWidth`. Baseline is a rolling median of the last 50 samples. Thresholds are persisted in `UserDefaults` and reloaded via `KnockDetector.reloadSettings()`.

**Onboarding** (`OnboardingView`): 4-step wizard that calibrates `knockThreshold` and `knockMaxGap` into `UserDefaults`. Creates its own `AccelerometerReader` + `KnockDetector` instances during calibration (torn down on exit). Completion posts `NSNotification.Name("OnboardingCompleted")` which `KnockController` observes to reload settings and activate.

**Settings** (`SettingsStore`): thin wrapper over `UserDefaults`. Keys: `knockThreshold` (Double, default 0.10g), `knockMaxGap` (Double, default 0.45s), `hasCompletedOnboarding` (Bool).

## Key Implementation Details

- `AccelerometerReader` uses a fixed `UnsafeMutablePointer<UInt8>` buffer (not a Swift Array) as IOKit-owned report storage to avoid COW invalidation. Self is retained via `Unmanaged.passRetained` for the C callback lifetime and released in `stop()`/`deinit`. Callback is unregistered before `IOHIDDeviceClose` to prevent use-after-free.
- `LidAngleSensor.isOpen` is currently a stub (always returns `true`).
- Swift 6 strict concurrency is enabled (`SWIFT_VERSION = 6.0`). All UI and controller code is `@MainActor`.
- The project uses **XcodeGen** (`project.yml`) — edit `project.yml` to add files/frameworks, then run `xcodegen generate`. Do not manually edit `.xcodeproj`.
- `knockMaxGap` is read directly from `UserDefaults` in `KnockDetector.reloadSettings()`, bypassing `SettingsStore` — both must be kept in sync when changing settings keys.
