# Detector v2: Adaptive + Shape + Gated Knock Detection

**Status:** Design
**Date:** 2026-04-16
**Scope:** Replace the current 5-algorithm voting detector with a 3-layer pipeline (Input Activity Gate → Adaptive Baseline → Shape Classifier).

## Problem

The current detector uses five per-sample algorithms that vote on whether a sample represents a knock. Three of the five (Magnitude, Jerk, Energy) are highly correlated — they all threshold on derivatives of the same magnitude signal. Only Z-Dominance and Impulse add structurally orthogonal information.

Problems this creates:
- **Fixed calibrated threshold doesn't adapt to context.** A threshold calibrated at a quiet desk fails on lap, couch, or while walking.
- **No negative evidence from user input.** The dominant source of false positives is typing; the detector has no awareness of keyboard/trackpad activity.
- **"3 of 5" is an illusion of robustness.** Correlated voters don't reduce false positives the way orthogonal voters would.
- **Sensitivity onboarding step requires user tuning** for a parameter the system could learn automatically.

## Goals

- Replace correlated magnitude-based algorithms with a small set of orthogonal filters.
- Adapt threshold automatically to ambient vibration (desk / lap / walking).
- Suppress samples that coincide with keyboard or trackpad activity.
- Classify candidate impulses by waveform shape (attack time, decay time, axis dominance, pre-impulse quiet).
- Remove the sensitivity slider from onboarding — system self-tunes.
- No new permission prompts beyond the existing Screen Recording requirement.
- Keep double-knock as the primary trigger, add shape-similarity check between the two knocks in a pair.

## Non-Goals

- CoreML or template-matching. Those are possible later if v2 is insufficient.
- Custom rhythm patterns (triple-knock, long-short). Out of scope for v2.
- Runtime detector switch (v1 vs v2 toggle). Git is the rollback mechanism.

## Architecture

### Data flow

```
AccelSample (100 Hz)
    │
    ▼
┌─────────────────────────────┐
│ InputActivityGate           │  Pull-based query: was there a keyDown
│                             │  or leftMouseDown in the last 300 ms?
└─────────────────────────────┘
    │ (suppress if recent input)
    ▼
┌─────────────────────────────┐
│ AdaptiveBaseline            │  Running mean + σ over ~2 s window.
│                             │  Frozen during active impulses.
│                             │  Threshold = max(absFloor, k · σ clamped).
└─────────────────────────────┘
    │ (deviation, threshold)
    ▼
┌─────────────────────────────┐
│ CandidateTracker            │  State machine: Idle → RisingEdge →
│                             │  Peaked → Decaying → Done. Collects
│                             │  20–30 samples around peak.
└─────────────────────────────┘
    │ (ImpulseWindow)
    ▼
┌─────────────────────────────┐
│ ShapeAnalyzer               │  Post-hoc classification of a complete
│                             │  impulse: attack/decay timing, Z-dominance,
│                             │  pre-impulse quiet. accept(peak) / reject(reason).
└─────────────────────────────┘
    │ (KnockEvent)
    ▼
┌─────────────────────────────┐
│ DoubleKnockMatcher          │  Pairs two KnockEvents if gap ∈ [min,max]
│                             │  AND shapes are similar (amplitude, attack ratio).
└─────────────────────────────┘
    │
    ▼
onDoubleKnock callback
```

### Components

#### InputActivityGate

Stateless query wrapper around `CGEventSource.secondsSinceLastEventType`.

```
final class InputActivityGate {
    let suppressionWindow: TimeInterval = 0.3

    func shouldSuppress() -> Bool {
        let tKey   = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let tClick = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        return min(tKey, tClick) < suppressionWindow
    }
}
```

**Verification:** The `secondsSinceLastEventType` API was smoke-tested during design. It returns live values without any permission prompt on macOS 14+.

**Tuning:** 300 ms default. Typing bursts can produce chassis vibration 50–100 ms after keypress; adjacent keys arrive ~100–200 ms apart. 300 ms provides headroom. Raise to 400 ms if fast-typing tests still leak false positives.

#### AdaptiveBaseline

Tracks running mean and standard deviation of magnitude over a rolling window. Emits a dynamic threshold (as a deviation-from-baseline magnitude).

```
final class AdaptiveBaseline {
    // Initial tuning values — subject to empirical adjustment
    private let windowSize = 200          // ~2 s at 100 Hz
    private let k = 6.0                   // threshold = k · σ
    private let sigmaFloor = 0.003        // prevent over-triggering in very quiet environments
    private let sigmaCeiling = 0.03       // prevent deafening in heavy vibration
    private let absoluteFloor = 0.025     // hard minimum deviation regardless of σ

    private var ring: [Double]            // ring buffer of recent magnitudes
    private var sum: Double
    private var sumOfSquares: Double      // maintained incrementally for O(1) σ
    private var frozen: Bool              // skip updates during active impulse

    var baseline: Double { sum / Double(count) }
    var sigma: Double {
        // clamped to [sigmaFloor, sigmaCeiling]
    }
    var thresholdDeviation: Double {
        max(absoluteFloor, k * sigma)
    }

    func feed(_ magnitude: Double)        // no-op if frozen
    func freeze() / unfreeze()            // called by CandidateTracker around impulses
}
```

**Why freeze during impulses:** The impulse itself is high variance. If σ includes impulse samples, it inflates for the next few seconds and makes the next knock harder to detect. Existing `updateBaseline` already applies this idea for the mean — we extend it to σ.

**Why floor/ceiling σ:**
- Floor: on a perfectly still granite desk, σ could approach zero, and a normal baseline-noise wobble would exceed `k · σ`. Floor keeps a sane minimum.
- Ceiling: in a moving car or with loud fans, σ can rise enough that real knocks no longer exceed `k · σ`. Ceiling prevents the detector from going deaf.

**Why `absoluteFloor` on threshold itself:** defense-in-depth. Even if σ behaves badly, we never trigger below 0.025 g deviation.

#### CandidateTracker

Simple state machine that recognizes an impulse start, collects samples until it decays, and emits an `ImpulseWindow`.

```
enum State { case idle, collecting }

struct ImpulseWindow {
    let samples: [AccelSample]   // peakIndex + surrounding context
    let peakIndex: Int
    let baseline: Double
}

final class CandidateTracker {
    private var state: State = .idle
    private var buffer: [AccelSample] = []
    private var preImpulseBuffer: [AccelSample] = []  // last 10 samples before impulse
    private var peakIndex: Int = 0
    private var peakDeviation: Double = 0

    var onImpulse: ((ImpulseWindow) -> Void)?

    func feed(_ sample: AccelSample, deviation: Double, threshold: Double, baseline: Double) {
        // Keep rolling pre-impulse buffer (for shape analyzer's pre-quiet check).
        // On state transitions: collect ≥20 samples or until deviation < threshold · 0.3
        // for ≥5 consecutive samples. Then emit ImpulseWindow(preBuffer + collected).
    }
}
```

**Peak tracking:** update `peakIndex` whenever a new sample exceeds the current peak during collection. Do not stop early on first drop — chassis resonance creates small oscillations; require sustained decay below 30% of threshold.

**Hard cap:** 30 samples (300 ms) collected max, to bound memory and guarantee forward progress.

#### ShapeAnalyzer

Classifies a complete `ImpulseWindow` as knock or non-knock using four orthogonal tests.

```
final class ShapeAnalyzer {
    // Initial tuning values
    private let maxAttackSamples = 4       // peak within 40 ms of impulse start (at 100 Hz)
    private let minDecaySamples = 2        // must actually decay
    private let maxAttackDecayRatio = 1.5  // decay at least ~as fast as attack
    private let minZDominance = 1.3        // |Δz| ≥ 1.3 · max(|Δx|, |Δy|) at peak
    private let maxPreQuietDeviation = 0.025  // average of pre-impulse samples within this of baseline

    enum Classification {
        case accept(peak: Double)
        case reject(reason: String)
    }

    func classify(_ window: ImpulseWindow) -> Classification {
        // 1. Pre-quiet: mean |mag - baseline| over preImpulseBuffer < maxPreQuietDeviation
        // 2. Attack: peakIndex - impulseStart ≤ maxAttackSamples
        // 3. Decay: exists index peakIndex+n where n ≤ 2·maxAttackSamples and
        //          (|mag - baseline|) < 0.5 · peakDeviation
        // 4. Z-dominance at peak: |Δz between peakIndex and peakIndex-1| > 1.3 · max(|Δx|,|Δy|)
        // Reject with specific reason if any test fails.
    }
}
```

**Rejection reasons** are surfaced through logging during tuning. Typical examples:
- `"slow_attack: 8 samples"` — plop or soft tap, not a knock.
- `"no_decay: plateau"` — sustained vibration, not an impulse.
- `"z_weak: dz/dxy=0.9"` — lateral motion, not a vertical knock.
- `"pre_noisy: avg_dev=0.04"` — detector caught a tail of another vibration.

#### DoubleKnockMatcher

Pairs two `KnockEvent`s based on timing gap and shape similarity.

```
struct KnockEvent {
    let time: TimeInterval
    let peak: Double
    let attackSamples: Int
}

final class DoubleKnockMatcher {
    private let minGap: TimeInterval = 0.175
    private let maxGap: TimeInterval = 0.325
    private var lastEvent: KnockEvent?

    var onDouble: ((TimeInterval, Double) -> Void)?
    var onSingle: ((Double) -> Void)?    // calibration mode only
    var singleKnockOnly = false

    func submit(_ event: KnockEvent, now: TimeInterval) {
        // Compare with lastEvent: gap ∈ [minGap, maxGap] AND shapeSimilar(...) → fire double.
        // Else store as new lastEvent.
    }

    private func shapeSimilar(_ a: KnockEvent, _ b: KnockEvent) -> Bool {
        let ampRatio = max(a.peak, b.peak) / min(a.peak, b.peak)
        let attackRatio = Double(max(a.attackSamples, b.attackSamples)) /
                          Double(min(a.attackSamples, b.attackSamples))
        return ampRatio <= 2.5 && attackRatio <= 2.0
    }
}
```

**Production cooldown** of 1.0 s between fired doubles remains (preserved from v1). Verification calibration uses 0.4 s (already applied in current code).

### Reassembled KnockDetector

```
final class KnockDetector {
    // Public API (mostly preserved):
    //   - feed(_:)                         — unchanged
    //   - onKnock                          — unchanged
    //   - onSingleKnock                    — unchanged (used by calibration)
    //   - onDoubleKnockWithGap             — unchanged (used by verification)
    //   - singleKnockOnly                  — unchanged (used by calibration)
    //   - cooldown                         — unchanged (used by verification: 0.4 s)
    //   - reloadSettings()                 — becomes no-op (no user-facing threshold left)
    //   - setCalibrationMode(threshold:)   — REMOVED (no single-threshold concept in v2)
    // Internals replaced with the pipeline above.
}
```

**External surface changes:**
- `setCalibrationMode(threshold:)` is removed. Callers in the old onboarding's sensitivity step are removed alongside it. Verification no longer needs a bespoke threshold — it runs the production detector.
- `reloadSettings()` stays in the API but becomes a no-op (the only setting it used to read, `knockThreshold`, is gone). `KnockController` still calls it after onboarding completes; that's harmless.
- `KnockController`, `AccelerometerReader`, `OnboardingView` otherwise unchanged in their interactions with the detector.

## Onboarding Changes

Remove Step 1 (Sensitivity slider) entirely. New flow:

1. **System Check** — screen recording + accelerometer detection.
2. **Where to knock** — visual explanation.
3. **Test it out** — three double-knocks, running the full v2 detector.

### Code changes in `OnboardingView.swift`

Remove:
- `sensitivitySlider`, `knockFlash`, `knockMarkerPos`, `knockMarkerOpacity` state.
- `sliderThreshold`, `sensitivityLabel`, `sensitivityLabelColor` computed properties.
- Entire `step == 2` block.
- `startSensitivityCalibration()` function.
- In `finishOnboarding`: the `UserDefaults.standard.set(finalThreshold, forKey: "knockThreshold")` call.

Renumber remaining steps (old step 3 becomes new step 2).

### SettingsStore

Remove the `knockThreshold` and `knockMaxGap` properties. The new detector's tuning lives in component constants, not user settings. `hasCompletedOnboarding` remains. The underlying `UserDefaults` keys are also no longer read by `KnockDetector.reloadSettings()`.

### UserDefaults migration

No migration needed. Old `knockThreshold` key is simply no longer read. It remains in user defaults harmlessly (removing it explicitly is optional cleanup).

## Rollback Plan

Before any implementation work:

```bash
git tag detector-v1-stable
git push origin detector-v1-stable
git checkout -b feature/detector-v2
```

All auto-commits land in `feature/detector-v2`; `main` stays at the v1-stable tag.

**If v2 does not prove out:**

```bash
git checkout main
# optionally: git branch -D feature/detector-v2
```

Tag `detector-v1-stable` is always available as a restore point regardless of branch state.

**When v2 is validated:**

Criterion: onboarding verification (3 double-knocks) passes first-try on desk, lap, and couch. Plus one day of real use without user-reported false positives or misses.

```bash
git checkout main
git merge feature/detector-v2
git push
```

## Tuning and Validation Plan

Parameters in `AdaptiveBaseline`, `ShapeAnalyzer`, and `InputActivityGate` are starting values. They will almost certainly need tuning after first implementation. Plan:

1. **Smoke test after build:**
   - Single double-knock on desk → fires.
   - Typing rapidly → does not fire.
   - Lift and place laptop → does not fire.
2. **Verbose rejection logging** enabled during tuning, with format: `[Shape] reject: reason=slow_attack; peak=0.08; attack=8`.
3. **Tuning criterion:** onboarding verification (3 doubles in a row) passes first-try on:
   - Stable desk
   - Laptop on lap
   - Laptop on couch
4. **Tuning knobs** — only adjust constants, never logic:
   - `k` (AdaptiveBaseline σ multiplier): raise to reduce sensitivity, lower to increase.
   - `maxAttackSamples` (ShapeAnalyzer): raise to accept slower impulses.
   - `suppressionWindow` (InputActivityGate): raise if typing leaks through.
   - `shapeSimilar` thresholds (DoubleKnockMatcher): relax if valid doubles get rejected.
5. **Abort criterion:** if tuning after 2–3 iterations still cannot pass the criterion above, revert to `detector-v1-stable` and reconsider.

## Testing

No unit test infrastructure currently exists in the project. Component testability is a design goal — each component has a narrow interface and can be exercised with synthetic `AccelSample` streams. If tests are added later, they'd live in a sibling target. For v2 the validation is the tuning criterion above.

## Open Questions

None at design time. All open questions from brainstorming resolved:
- Permission model: `CGEventSource` query works without permissions (verified).
- Rollback: git-only (tag + branch), no runtime flag.
- Onboarding: sensitivity slider removed.

## Out of Scope for This Spec

- Actual implementation tasks and ordering — that's the job of the follow-up implementation plan.
- CoreML classifier, template matching, spectral analysis — possible future enhancements if v2 is insufficient.
- Custom knock patterns (triple, rhythmic) — separate feature request.
