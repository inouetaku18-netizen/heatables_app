# Calmables Live Demo — Changes since `demo-v2`

A guided, conference-ready demo flow was added on top of the existing Calmables app.
It reuses the existing architecture end to end: the PPG/HR pipeline (`PpgFilter`),
the baseline/trigger calculation (`HrCalibration`), and the single BLE control path
into the Calmables device (`sendDataToCalmables`). No physiological values are
simulated or modified anywhere.

## Changed files

| File | Change |
|---|---|
| `open_wearable/lib/apps/calmables/widgets/live_demo_page.dart` | **New** — the entire guided demo (state machine, all screens, survey results) |
| `open_wearable/lib/apps/calmables/widgets/calmables_page.dart` | "Live Demo" button in the app bar; hands exclusive thermal control to the demo (cancels autopilot / manual heating before launch) |
| `open_wearable/lib/apps/calmables/widgets/rolling_hr_chart.dart` | Optional baseline/trigger reference lines; optional seed data so charts never start empty |
| `open_wearable/lib/apps/calmables/model/hr_calibration.dart` | Computed trigger threshold is now at least **baseline + 15 BPM** (`max(baseline + 15, mean + 3σ)`) — also applies to the autopilot mode |

## Entry point

The **Live Demo** button appears in the Calmables page app bar once the HR pipeline
is streaming. Opening the demo switches the main page to manual mode, turns any
running heating off, and passes the live streams, the shared `HrCalibration`
instance, and the BLE send callback into the demo page.

## The flow

```
Ready → Warmth intensity → Baseline → Brief activation → Breathing
      → Relaxation intro → Relaxation → Welcome back
      → Survey statement 1 → Survey statement 2 → Summary  (→ Start Again)
Exit (X / back) at any point → Survey results list
```

### 1. Ready
Logo, tagline, and compact connection status for the HR source (earable) and the
Calmables device (with a *Connect* action if disconnected). **Start Demo** is
enabled once a live HR signal is present.

### 2. Warmth intensity
One panel like the main Calmables page: **ON/OFF switch** plus the **gradient
slider (0–255)** with a color-coded Off/Low/Medium/High label.

- On entering, preview heating switches **on automatically** at the current
  slider value (default 130) so the participant feels it immediately.
- Slider changes are sent live while ON; the switch can turn the preview off.
- Leaving via **Continue** always switches heating off.
- The chosen value is used for the thermal feedback of the whole run.

HR is measured in the background the entire time (signal, current BPM, and a
rolling 60 s chart history), but the baseline **aggregation does not start here**.

### 3. Baseline
The 30-second baseline aggregation starts **only when this step is entered**
(via the Continue button). Shows the live heart rate, baseline and trigger
threshold tiles, and a live HR chart with baseline/trigger reference lines —
pre-seeded with the last 60 s of history, so there is no "waiting for signal".
**Continue** unlocks when the measurement is done; *Restart measurement* is
available.

- Baseline = mean HR of the window; trigger = `max(baseline + 15, mean + 3σ)`
  (rolling updates continue afterwards; manual overrides stay untouched).

### 4. Brief activation → Breathing
After an intro screen, a pulsing circle guides fast breathing:

- Breath rate ramps from **30 to 50 breaths/min over 10 s**, then holds.
- No "In/Out" labels; strong expand/contract animation (reduced-motion aware).
- Current HR, trigger threshold, and the live HR chart stay visible.
- **No time limit** — breathing continues until the trigger fires.

**Trigger:** evaluated continuously on the smoothed (Kalman-filtered) HR, on
every sample — the same condition as the HR-based autopilot mode
(`HR > trigger threshold`), debounced over **3 consecutive samples** so a single
artifact cannot fire it. The moment it fires, heating starts immediately at the
chosen intensity (`triggerSource = automatic`) and the flow jumps straight to
the relaxation intro — the breathing animation never delays it.

**Demo Trigger fallback:** if no trigger occurred after **20 s**, a
*Continue with Demo Trigger* button fades in below the breathing visual. It does
not touch any HR value — it starts the same safe thermal pathway and records
`triggerSource = demo`.

### 5. Relaxation
Intro screen ("Take a moment to notice the warmth" / "You can breathe normally
again.") → **I'm ready** → a calm, minimal screen with a slowly drifting circle,
a small live BPM readout, and the HR chart.

There is **no countdown timer**. Rules:

- The relaxation runs at least **25 s**, regardless of HR.
- After that, heating stays on until the smoothed HR falls below the
  **deactivation threshold** — `baseline + 0.2 × (trigger − baseline)`, the same
  hysteresis the autopilot uses — for 3 consecutive samples.
- After **30 s** a subtle *End relaxation* button appears as a manual way out.

On completion: heating stops through the normal path, and the phone **vibrates
repeatedly** (full system vibration, once per second).

### 6. Welcome back
Shows "Welcome back" and keeps vibrating until the participant taps **I'm back**.

### 7. Survey
Two statements, each rated on a **vertical 7-point Likert scale**
(1 – Strongly Disagree … 7 – Strongly Agree). One tap selects and advances:

1. *The device helped me feel more relaxed.*
2. *I would use this device during stressful days in private.*

### 8. Summary
Compact card: Baseline, Peak HR (tracked from breathing through relaxation),
Trigger (Automatic/Demo), Intensity (e.g. "Medium · 130"), and both agreement
ratings (e.g. "6 / 7").
**Start Again** stops heating, clears participant state, and schedules a fresh
baseline calibration for the next participant — BLE connections and the chosen
intensity are kept.

## Survey results

Every run that reached the survey is stored as a `DemoSurveyResult`
(timestamp, intensity, baseline, peak HR, trigger source, and both 1–7
agreement scores) in an in-memory session list. The list is **only visible when leaving the demo flow**
(X or system back): exiting first saves an unfinished-but-rated run, then shows
the *Survey results* page with one card per run. The list survives re-entering
the demo but not an app restart.

## Design

- iOS-style single-purpose screens: one primary action, generous spacing,
  system typography, large touch targets, subtle fade transitions, safe areas,
  Dynamic Type, and reduced-motion support.
- Panel backgrounds (status rows, stat tiles, chart backgrounds, summary cards,
  slider panel) use a **neutral grey** (`#F1F1F3` light / `#2A2A2C` dark)
  instead of the pink-tinted Material 3 surfaces coming from the app's rosé
  seed color. Accent color remains the Calmables teal (`#009682`).

## Safety notes

- Every heating command (preview, trigger, stop) goes through the single
  existing `sendDataToCalmables` path; nothing bypasses or duplicates it.
- Heating is switched off between phases, on *Start Again*, on exit, and on
  page dispose; launching the demo also disables autopilot/manual control so
  only one controller writes PWM at a time.
- There is still **no app-side maximum heating duration** (none existed before
  either) — during relaxation, heat stays on until HR recovery, the manual end,
  or exit. Firmware-side limits are unchanged and remain the hard safety net.
