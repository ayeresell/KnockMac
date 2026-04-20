<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey?style=flat&logo=apple&logoColor=white"/>
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?style=flat&logo=swift&logoColor=white"/>
  <img src="https://img.shields.io/badge/SwiftUI-blue?style=flat&logo=swift&logoColor=white"/>
  <img src="https://img.shields.io/badge/Apple_Silicon-only-black?style=flat&logo=apple&logoColor=white"/>
</p>

<h2 align="center">KnockMac — take screenshots by knocking on your laptop</h2>
<p align="center">A menu bar app that listens to the built-in accelerometer and captures the screen when you double-knock the body of your Mac.</p>

---

## How It Works

```
Apple Silicon IMU  (IOKit HID, vendor 0x05AC)
          │
          ▼
 AccelerometerReader — ~100 Hz samples
          │
          ▼
   KnockDetector  ──▶  5-algorithm voting
          │             ├── MagnitudeThreshold
          │             ├── Jerk
          │             ├── Energy
          │             ├── ZAxisDominance
          │             └── PeakWidth
          │
          │  ≥3/5 votes = knock registered
          ▼
  Two knocks within 0.08…0.45 s = trigger
          │
          ▼
 ScreenCaptureKit  ──▶  PNG on Desktop
```

## Features

- **Physical trigger** — no keyboard, no hotkey; just tap twice on the laptop body
- **Adaptive detection** — 5-algorithm voting over a rolling baseline median of the last 50 samples
- **Calibration wizard** — first-launch flow tunes sensitivity and knock gap to each user
- **Invisible** — lives in the menu bar, no Dock icon (`LSUIElement = true`)
- **Privacy-first** — all processing is local, no network access
- **Standard TCC flow** — uses Screen Recording permission like any other screenshot tool

## Tech Stack

| Layer | Technology |
|-------|-----------|
| UI | SwiftUI + `MenuBarExtra` |
| Concurrency | Swift 6 strict concurrency, `@MainActor` |
| IMU access | IOKit HID (`IOHIDManager` / `IOHIDEventSystemClient`) |
| Screen capture | ScreenCaptureKit |
| Persistence | UserDefaults |
| Project generation | XcodeGen |

## Requirements

- macOS 15 Sequoia or later
- Apple Silicon (M1 or later) — IMU is not exposed on Intel Macs
- Screen Recording permission

## Getting Started

```bash
git clone https://github.com/ayeresell/KnockMac.git
cd KnockMac
xcodegen generate
open KnockMac.xcodeproj
```

1. Build & run in Xcode
2. Grant **Screen Recording** permission (`System Settings → Privacy & Security → Screen Recording`)
3. Complete the 4-step calibration wizard
4. Double-knock anywhere on the body of your Mac — screenshot lands at `~/Desktop/KnockMac-<timestamp>.png`

## Settings

Detection parameters are persisted in `UserDefaults`:

| Key | Default | Meaning |
|-----|---------|---------|
| `knockThreshold` | `0.10` (g) | minimum magnitude above baseline |
| `knockMaxGap` | `0.45` (s) | maximum delay between the two knocks |
| `hasCompletedOnboarding` | `false` | shows calibration wizard on first launch |

Reset onboarding in DEBUG builds by passing `--reset-onboarding` as a launch argument.

---

<details>
<summary>🇷🇺 На русском</summary>

**KnockMac** — приложение в строке меню macOS, которое делает скриншот по двойному стуку по корпусу ноутбука.

Читает сырые данные акселерометра Apple Silicon через IOKit HID (~100 Гц) и детектирует стук системой голосования из 5 алгоритмов: `MagnitudeThreshold`, `Jerk`, `Energy`, `ZAxisDominance`, `PeakWidth`. Нужно минимум 3 из 5 голосов. Два стука с интервалом 0.08–0.45 с = триггер. Скриншот сохраняется в `~/Desktop/KnockMac-<timestamp>.png`.

При первом запуске — калибровочный визард из 4 шагов, который подстраивает чувствительность и интервал между стуками под конкретного пользователя.

**Требования:** macOS 15+, Apple Silicon, разрешение Screen Recording.

</details>
