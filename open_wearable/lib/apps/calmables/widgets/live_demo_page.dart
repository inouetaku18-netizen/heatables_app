import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_wearable/apps/calmables/model/hr_calibration.dart';
import 'package:open_wearable/apps/calmables/model/ppg_filter.dart';
import 'package:open_wearable/apps/calmables/widgets/rolling_hr_chart.dart';

/// How the thermal feedback of the current demo run was started.
enum DemoTriggerSource { automatic, demo }

/// Survey answers and key metrics of one completed demo run.
class DemoSurveyResult {
  final DateTime timestamp;
  final String intensity;
  final double? baseline;
  final double? peakHr;
  final DemoTriggerSource? triggerSource;
  final String? warmthRating;
  final String? relaxationRating;

  const DemoSurveyResult({
    required this.timestamp,
    required this.intensity,
    this.baseline,
    this.peakHr,
    this.triggerSource,
    this.warmthRating,
    this.relaxationRating,
  });
}

enum _DemoStep {
  ready,
  intensitySelect,
  baseline,
  activationIntro,
  breathing,
  relaxationIntro,
  relaxationRunning,
  welcomeBack,
  warmthRating,
  relaxationRating,
  summary,
}

/// Guided conference demo flow.
///
/// Reuses the existing HR pipeline ([PpgFilter] streams), the existing
/// baseline/trigger calculation ([HrCalibration]) and the single existing
/// BLE control path into the Calmables device (`onSendToCalmables`).
/// No physiological values are simulated or modified anywhere in this flow.
class LiveDemoPage extends StatefulWidget {
  final Stream<double?> heartRateStream;
  final Stream<PpgSignalQuality> signalQualityStream;
  final Stream<(int, double)> rawHrStream;
  final Stream<(int, double)> smoothedHrStream;
  final int timestampExponent;
  final HrCalibration calibration;
  final String hrSourceName;
  final bool Function() isCalmablesConnected;
  final Future<bool> Function() onConnectCalmables;
  final Future<bool> Function(List<int>) onSendToCalmables;

  const LiveDemoPage({
    super.key,
    required this.heartRateStream,
    required this.signalQualityStream,
    required this.rawHrStream,
    required this.smoothedHrStream,
    required this.timestampExponent,
    required this.calibration,
    required this.hrSourceName,
    required this.isCalmablesConnected,
    required this.onConnectCalmables,
    required this.onSendToCalmables,
  });

  /// Survey results collected across all demo runs of this app session.
  /// Only shown when leaving the demo flow.
  static final List<DemoSurveyResult> sessionResults = [];

  @override
  State<LiveDemoPage> createState() => _LiveDemoPageState();
}

class _LiveDemoPageState extends State<LiveDemoPage>
    with TickerProviderStateMixin {
  static const Color _accent = Color(0xFF009682);

  // PWM levels stay inside the existing warmth bands used by the manual
  // control (<85 low, <170 medium, >=170 high). No new safety parameters —
  // every write goes through the same central BLE path as manual control.
  static const int _pwmLow = 70;
  static const int _pwmMedium = 130;
  static const int _pwmHigh = 200;

  // Guided breathing ramps from 30 breaths/min up to 50 breaths/min over
  // the breathing phase.
  static const double _breathStartHz = 30 / 60;
  static const double _breathEndHz = 50 / 60;
  static const Duration _breathRampDuration = Duration(seconds: 10);
  static const Duration _demoTriggerRevealDelay = Duration(seconds: 20);
  static const Duration _relaxEndOptionDelay = Duration(seconds: 30);
  static const Duration _welcomeBackDuration = Duration(milliseconds: 1800);

  static const List<String> _intensityLevels = ['Low', 'Medium', 'High'];
  static const List<int> _intensityPwm = [_pwmLow, _pwmMedium, _pwmHigh];

  _DemoStep _step = _DemoStep.ready;

  // Live signal state
  StreamSubscription<double?>? _hrSub;
  StreamSubscription<PpgSignalQuality>? _qualitySub;
  StreamSubscription<(int, double)>? _rawChartSub;
  StreamSubscription<(int, double)>? _smoothedChartSub;

  // Rolling HR history kept across all demo phases so charts never start
  // empty when a new screen appears.
  static const int _chartHistorySeconds = 60;
  final List<(int, double)> _rawHrHistory = [];
  final List<(int, double)> _smoothedHrHistory = [];

  double? _currentHr;
  DateTime? _lastHrSampleAt;
  DateTime _lastHrUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  PpgSignalQuality _quality = PpgSignalQuality.unavailable;

  // Demo session state
  DemoTriggerSource? _triggerSource;
  bool _thermalStarted = false;
  int _currentPwm = 0;
  double? _peakHr;
  bool _trackPeak = false;
  String? _warmthRating;
  String? _relaxationRating;
  bool _demoTriggerAvailable = false;
  bool _recalibrateOnNextRun = false;
  int _selectedIntensityIndex = 1;
  bool _resultSaved = false;
  int _aboveThresholdCount = 0;
  DateTime? _breathingStartedAt;

  // Relaxation: heating stays active until the (smoothed) HR falls back
  // below the deactivation threshold — the same hysteresis value the
  // HR-based autopilot mode uses. Armed once HR has been elevated so a
  // demo-triggered run does not end immediately.
  bool _relaxDeactivationArmed = false;
  int _belowThresholdCount = 0;
  bool _relaxEndAvailable = false;

  /// Consecutive HR samples above threshold required to fire the trigger, so
  /// a single spike/artifact in the smoothed HR cannot end the breathing
  /// phase prematurely.
  static const int _triggerDebounceSamples = 3;

  // Timers & animation
  Timer? _stepTimer;
  Timer? _demoRevealTimer;
  Timer? _uiTick;
  AnimationController? _breathingController;
  AnimationController? _relaxationController;

  bool get _reducedMotion => MediaQuery.of(context).disableAnimations;

  @override
  void initState() {
    super.initState();
    _hrSub = widget.heartRateStream.listen(_onHeartRate);
    _qualitySub = widget.signalQualityStream.listen((q) {
      if (!mounted || q == _quality) return;
      setState(() => _quality = q);
    });
    final ticksPerSecond = pow(10, -widget.timestampExponent).toDouble();
    void addPoint(List<(int, double)> history, (int, double) point) {
      if (!point.$2.isFinite) return;
      history.add(point);
      final cutoff =
          point.$1 - (_chartHistorySeconds * ticksPerSecond).round();
      while (history.isNotEmpty && history.first.$1 < cutoff) {
        history.removeAt(0);
      }
    }

    _rawChartSub =
        widget.rawHrStream.listen((p) => addPoint(_rawHrHistory, p));
    _smoothedChartSub =
        widget.smoothedHrStream.listen((p) => addPoint(_smoothedHrHistory, p));
  }

  @override
  void dispose() {
    _hrSub?.cancel();
    _qualitySub?.cancel();
    _rawChartSub?.cancel();
    _smoothedChartSub?.cancel();
    _cancelTimers();
    _breathingController?.dispose();
    _relaxationController?.dispose();
    if (_currentPwm != 0) {
      // Fire-and-forget stop through the normal control path.
      unawaited(widget.onSendToCalmables([0]));
    }
    super.dispose();
  }

  void _cancelTimers() {
    _stepTimer?.cancel();
    _stepTimer = null;
    _demoRevealTimer?.cancel();
    _demoRevealTimer = null;
    _uiTick?.cancel();
    _uiTick = null;
  }

  // ── Signal handling ─────────────────────────────────────────────────────────

  void _onHeartRate(double? bpm) {
    if (bpm == null || !bpm.isFinite) return;
    _currentHr = bpm;
    _lastHrSampleAt = DateTime.now();
    if (_trackPeak && (_peakHr == null || bpm > _peakHr!)) {
      _peakHr = bpm;
    }

    // Continuous evaluation of the existing trigger condition (same condition
    // as the HR-based autopilot mode). Breathing has no time limit — it ends
    // only when the trigger fires (automatic or demo).
    if (!_thermalStarted && _step == _DemoStep.breathing) {
      final result = widget.calibration.latestResult;
      if (result != null && bpm > result.triggerThreshold) {
        _aboveThresholdCount++;
        if (_aboveThresholdCount >= _triggerDebounceSamples) {
          _onAutomaticTrigger();
          return;
        }
      } else {
        _aboveThresholdCount = 0;
      }
    }

    // During relaxation, heating stays on until HR has recovered below the
    // deactivation threshold (same hysteresis as the autopilot mode).
    if (_step == _DemoStep.relaxationRunning) {
      final result = widget.calibration.latestResult;
      if (result != null) {
        final deactivateThreshold = result.baselineHeartRate +
            0.2 * (result.triggerThreshold - result.baselineHeartRate);
        if (bpm >= deactivateThreshold) {
          _relaxDeactivationArmed = true;
          _belowThresholdCount = 0;
        } else if (_relaxDeactivationArmed) {
          _belowThresholdCount++;
          if (_belowThresholdCount >= _triggerDebounceSamples) {
            _onRelaxationComplete();
            return;
          }
        }
      }
    }
    // Throttle UI rebuilds; the trigger evaluation above runs per sample.
    final now = DateTime.now();
    if (mounted &&
        now.difference(_lastHrUiUpdate) > const Duration(milliseconds: 250)) {
      _lastHrUiUpdate = now;
      setState(() {});
    }
  }

  bool get _hrSignalActive {
    final last = _lastHrSampleAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 5)) {
      return true;
    }
    return _quality != PpgSignalQuality.unavailable;
  }

  // ── Thermal control (single centralized path) ──────────────────────────────

  Future<void> _setPwm(int pwm) async {
    if (_currentPwm == pwm) return;
    _currentPwm = pwm;
    await widget.onSendToCalmables([pwm]);
  }

  void _startThermalFeedback(DemoTriggerSource source) {
    if (_thermalStarted) return;
    _thermalStarted = true;
    _triggerSource = source;
    unawaited(_setPwm(_intensityPwm[_selectedIntensityIndex]));
  }

  // ── State machine transitions ──────────────────────────────────────────────

  void _goTo(_DemoStep step) {
    _cancelTimers();
    _breathingController?.stop();
    setState(() => _step = step);

    switch (step) {
      case _DemoStep.intensitySelect:
        // Preview the pre-selected level right away so tapping is only
        // needed to switch levels.
        unawaited(_setPwm(_intensityPwm[_selectedIntensityIndex]));
        // Start measuring the resting baseline in the background already,
        // so the next step has valid heart rates from the start.
        _startBackgroundCalibration();
      case _DemoStep.baseline:
        _enterBaseline();
      case _DemoStep.breathing:
        _enterBreathing();
      case _DemoStep.relaxationRunning:
        _enterRelaxation();
      case _DemoStep.welcomeBack:
        _stepTimer = Timer(
          _welcomeBackDuration,
          () => _goTo(_DemoStep.warmthRating),
        );
      case _DemoStep.summary:
        _saveSurveyResult();
      default:
        break;
    }
  }

  void _saveSurveyResult() {
    if (_resultSaved) return;
    if (_warmthRating == null && _relaxationRating == null) return;
    _resultSaved = true;
    LiveDemoPage.sessionResults.add(
      DemoSurveyResult(
        timestamp: DateTime.now(),
        intensity: _intensityLevels[_selectedIntensityIndex],
        baseline: widget.calibration.latestResult?.baselineHeartRate,
        peakHr: _peakHr,
        triggerSource: _triggerSource,
        warmthRating: _warmthRating,
        relaxationRating: _relaxationRating,
      ),
    );
  }

  /// Leaving the flow: capture an unfinished run's ratings, then show the
  /// collected survey results (only visible outside the demo flow).
  void _exitDemo() {
    _saveSurveyResult();
    if (LiveDemoPage.sessionResults.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => SurveyResultsPage(
          results: List.of(LiveDemoPage.sessionResults),
        ),
      ),
    );
  }

  /// Starts (or restarts) the baseline calibration if needed. Runs silently
  /// in the background; the baseline screen only visualizes its state.
  void _startBackgroundCalibration() {
    final calibration = widget.calibration;
    if (calibration.isCalibrating) return;
    if (_recalibrateOnNextRun || calibration.latestResult == null) {
      _recalibrateOnNextRun = false;
      // stop() before start() so the existing subscriptions are re-created
      // cleanly for the next participant.
      calibration.stop();
      calibration.start(
        heartRateStream: widget.heartRateStream,
        signalQualityStream: widget.signalQualityStream,
      );
    }
  }

  void _enterBaseline() {
    // Fallback in case the background calibration was not started yet.
    _startBackgroundCalibration();
    _uiTick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  void _enterBreathing() {
    _trackPeak = true;
    _aboveThresholdCount = 0;
    _breathingStartedAt = DateTime.now();
    _breathingController?.dispose();
    // Pure ticker driving the pulse; the widget derives the ramping breath
    // cycle from the elapsed time. Breathing has no time limit — it ends
    // only when the trigger fires.
    _breathingController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    // If the trigger has not fired after a while, reveal the optional
    // Demo Trigger fallback below the breathing visual.
    _demoTriggerAvailable = false;
    _demoRevealTimer = Timer(_demoTriggerRevealDelay, () {
      if (mounted) setState(() => _demoTriggerAvailable = true);
    });
  }

  void _onAutomaticTrigger() {
    // Immediate: stop the breathing visual, cancel remaining timers, start
    // the thermal feedback through the existing safe control path and go
    // straight to the relaxation experience.
    _cancelTimers();
    _breathingController?.stop();
    _startThermalFeedback(DemoTriggerSource.automatic);
    if (mounted) setState(() => _step = _DemoStep.relaxationIntro);
  }

  void _onDemoTrigger() {
    // Does not change or fake any HR value — only starts the same safe
    // thermal pathway and records the source as "demo".
    _cancelTimers();
    _startThermalFeedback(DemoTriggerSource.demo);
    _goTo(_DemoStep.relaxationIntro);
  }

  void _enterRelaxation() {
    _relaxDeactivationArmed = false;
    _belowThresholdCount = 0;
    _relaxEndAvailable = false;
    _relaxationController?.dispose();
    // Slow ambient cycle for the visual — relaxation is not time-limited;
    // it ends when HR recovers (see _onHeartRate) or via the manual option.
    _relaxationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
    _stepTimer = Timer(_relaxEndOptionDelay, () {
      if (mounted) setState(() => _relaxEndAvailable = true);
    });
  }

  void _onRelaxationComplete() {
    if (_step != _DemoStep.relaxationRunning) return;
    unawaited(_setPwm(0));
    _trackPeak = false;
    unawaited(_playReturnHaptic());
    _goTo(_DemoStep.welcomeBack);
  }

  /// A short pattern of pulses is easier to notice than a single click,
  /// while still feeling gentle.
  Future<void> _playReturnHaptic() async {
    for (var i = 0; i < 3; i++) {
      await HapticFeedback.mediumImpact();
      await Future<void>.delayed(const Duration(milliseconds: 220));
    }
  }

  // ── Ratings ────────────────────────────────────────────────────────────────

  void _selectWarmthRating(String value) {
    unawaited(HapticFeedback.selectionClick());
    _warmthRating = value;
    _goTo(_DemoStep.relaxationRating);
  }

  void _selectRelaxationRating(String value) {
    unawaited(HapticFeedback.selectionClick());
    _relaxationRating = value;
    _goTo(_DemoStep.summary);
  }

  // ── Reset ──────────────────────────────────────────────────────────────────

  void _startAgain() {
    _cancelTimers();
    _breathingController?.stop();
    _relaxationController?.stop();
    unawaited(_setPwm(0));
    setState(() {
      _step = _DemoStep.ready;
      _triggerSource = null;
      _thermalStarted = false;
      _warmthRating = null;
      _relaxationRating = null;
      _peakHr = null;
      _trackPeak = false;
      _demoTriggerAvailable = false;
      _resultSaved = false;
      _aboveThresholdCount = 0;
      _breathingStartedAt = null;
      _relaxDeactivationArmed = false;
      _belowThresholdCount = 0;
      _relaxEndAvailable = false;
      // Next participant gets a fresh personal baseline; BLE connections
      // are intentionally preserved.
      _recalibrateOnNextRun = true;
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final body = switch (_step) {
      _DemoStep.ready => _buildReady(),
      _DemoStep.intensitySelect => _buildIntensitySelect(),
      _DemoStep.baseline => _buildBaseline(),
      _DemoStep.activationIntro => _buildActivationIntro(),
      _DemoStep.breathing => _buildBreathing(),
      _DemoStep.relaxationIntro => _buildRelaxationIntro(),
      _DemoStep.relaxationRunning => _buildRelaxationRunning(),
      _DemoStep.welcomeBack => _buildWelcomeBack(),
      _DemoStep.warmthRating => _buildRatingScreen(
          question: 'How did the warmth feel?',
          options: const ['Barely noticeable', 'Comfortable', 'Too warm'],
          onSelected: _selectWarmthRating,
        ),
      _DemoStep.relaxationRating => _buildRatingScreen(
          question: 'Did the thermal feedback feel relaxing?',
          options: const ['Not really', 'Somewhat', 'Yes'],
          onSelected: _selectRelaxationRating,
        ),
      _DemoStep.summary => _buildSummary(),
    };

    final isQuiet = _step == _DemoStep.relaxationRunning ||
        _step == _DemoStep.welcomeBack;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitDemo();
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        appBar: isQuiet
            ? null
            : AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
                leading: IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Exit demo',
                  onPressed: _exitDemo,
                ),
              ),
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: _reducedMotion
                ? Duration.zero
                : const Duration(milliseconds: 320),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: child,
            ),
            child: KeyedSubtree(
              key: ValueKey(_step),
              child: body,
            ),
          ),
        ),
      ),
    );
  }

  // ── Screens ────────────────────────────────────────────────────────────────

  Widget _buildReady() {
    final theme = Theme.of(context);
    final calmablesConnected = widget.isCalmablesConnected();

    return _ScreenFrame(
      scrollable: true,
      footer: _PrimaryButton(
        label: 'Start Demo',
        onPressed:
            _hrSignalActive ? () => _goTo(_DemoStep.intensitySelect) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.spa_rounded, size: 42, color: _accent),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Calmables',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Thermal biofeedback for short moments of recovery',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 32),
          _StatusRow(
            icon: Icons.favorite_rounded,
            label: widget.hrSourceName,
            connected: _hrSignalActive,
            statusText: _hrSignalActive ? 'Streaming' : 'No signal',
          ),
          const SizedBox(height: 10),
          _StatusRow(
            icon: Icons.thermostat_rounded,
            label: 'Calmables earable',
            connected: calmablesConnected,
            statusText: calmablesConnected ? 'Connected' : 'Not connected',
            trailing: calmablesConnected
                ? null
                : TextButton(
                    onPressed: () async {
                      await widget.onConnectCalmables();
                      if (mounted) setState(() {});
                    },
                    child: const Text('Connect'),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildIntensitySelect() {
    final theme = Theme.of(context);
    return _ScreenFrame(
      scrollable: true,
      footer: _PrimaryButton(
        label: 'Continue',
        onPressed: () {
          // Stop the preview heating before moving on.
          unawaited(_setPwm(0));
          _goTo(_DemoStep.baseline);
        },
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.thermostat_rounded,
                size: 36,
                color: _accent,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Warmth intensity',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Tap a level to feel it. The selected level is used for the '
            'thermal feedback.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 28),
          for (var i = 0; i < _intensityLevels.length; i++) ...[
            _IntensityOption(
              label: _intensityLevels[i],
              selected: _selectedIntensityIndex == i,
              onTap: () {
                unawaited(HapticFeedback.selectionClick());
                setState(() => _selectedIntensityIndex = i);
                // Preview the tapped level through the normal control path;
                // it is switched off again when leaving this screen.
                unawaited(_setPwm(_intensityPwm[i]));
              },
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _buildBaseline() {
    final theme = Theme.of(context);
    final calibration = widget.calibration;
    final result = calibration.latestResult;
    final isCalibrating = calibration.isCalibrating;
    final ready = result != null && !isCalibrating;
    final hr = _currentHr;

    return _ScreenFrame(
      scrollable: true,
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCalibrating) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: calibration.progressFraction,
                minHeight: 4,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                valueColor: const AlwaysStoppedAnimation<Color>(_accent),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Measuring your resting baseline…',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
          ],
          _PrimaryButton(
            label: 'Continue',
            onPressed: ready ? () => _goTo(_DemoStep.activationIntro) : null,
          ),
          TextButton(
            onPressed: isCalibrating
                ? null
                : () {
                    _recalibrateOnNextRun = true;
                    _goTo(_DemoStep.baseline);
                  },
            child: const Text('Restart measurement'),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Your resting heart rate',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Calmables uses your personal resting baseline to recognize '
            'temporary heart-rate elevation.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 28),
          Center(
            child: Column(
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      hr != null && hr.isFinite ? hr.toStringAsFixed(0) : '--',
                      style: theme.textTheme.displayLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: -1,
                        height: 1,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 6, bottom: 8),
                      child: Text(
                        'BPM',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Current heart rate',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: _StatTile(
                  label: 'Baseline',
                  value: result != null
                      ? result.baselineHeartRate.toStringAsFixed(0)
                      : '--',
                  unit: 'BPM',
                  color: _accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatTile(
                  label: 'Trigger threshold',
                  value: result != null
                      ? result.triggerThreshold.toStringAsFixed(0)
                      : '--',
                  unit: 'BPM',
                  color: const Color(0xFFFF8F00),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _ChartCard(
            child: SizedBox(
              height: 150,
              child: RollingHrChart(
                rawHrStream: widget.rawHrStream,
                smoothedHrStream: widget.smoothedHrStream,
                initialRawData: _rawHrHistory,
                initialSmoothedData: _smoothedHrHistory,
                timestampExponent: widget.timestampExponent,
                timeWindow: 60,
                baseline: result?.baselineHeartRate,
                threshold: result?.triggerThreshold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActivationIntro() {
    final theme = Theme.of(context);
    return _ScreenFrame(
      footer: _PrimaryButton(
        label: 'Start',
        onPressed: () => _goTo(_DemoStep.breathing),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.air_rounded, size: 36, color: _accent),
            ),
          ),
          const SizedBox(height: 28),
          Text(
            'Brief activation',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Follow the pulse and match your breathing to its rhythm.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.4),
          ),
          const SizedBox(height: 12),
          Text(
            'Keep your breathing light and comfortable. '
            'You can stop at any time.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBreathing() {
    return _ScreenFrame(
      footer: AnimatedOpacity(
        duration: _reducedMotion
            ? Duration.zero
            : const Duration(milliseconds: 400),
        opacity: _demoTriggerAvailable ? 1 : 0,
        child: IgnorePointer(
          ignoring: !_demoTriggerAvailable,
          child: _PrimaryButton(
            label: 'Continue with Demo Trigger',
            onPressed: _onDemoTrigger,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _hrAndThresholdRow(),
          Expanded(
            child: Center(
              child: _BreathingPulse(
                controller: _breathingController!,
                reducedMotion: _reducedMotion,
                startTime: _breathingStartedAt ?? DateTime.now(),
                rampSeconds: _breathRampDuration.inSeconds.toDouble(),
                startHz: _breathStartHz,
                endHz: _breathEndHz,
              ),
            ),
          ),
          _ChartCard(
            child: SizedBox(
              height: 120,
              child: RollingHrChart(
                rawHrStream: widget.rawHrStream,
                smoothedHrStream: widget.smoothedHrStream,
                initialRawData: _rawHrHistory,
                initialSmoothedData: _smoothedHrHistory,
                timestampExponent: widget.timestampExponent,
                timeWindow: 60,
                baseline: widget.calibration.latestResult?.baselineHeartRate,
                threshold: widget.calibration.latestResult?.triggerThreshold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRelaxationIntro() {
    final theme = Theme.of(context);
    return _ScreenFrame(
      footer: _PrimaryButton(
        label: "I'm ready",
        onPressed: () => _goTo(_DemoStep.relaxationRunning),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.self_improvement_rounded,
                size: 36,
                color: _accent,
              ),
            ),
          ),
          const SizedBox(height: 28),
          Text(
            'Take a moment to notice the warmth',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'You can breathe normally again.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Feel free to close your eyes and focus on the sensation. '
            "We'll gently bring you back in a few moments.",
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRelaxationRunning() {
    final theme = Theme.of(context);
    final controller = _relaxationController;
    final hr = _currentHr;
    return Column(
      children: [
        Expanded(
          child: Center(
            child: controller == null
                ? const SizedBox.shrink()
                : _RelaxationCircle(
                    controller: controller,
                    reducedMotion: _reducedMotion,
                  ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.favorite_rounded, size: 16, color: _accent),
            const SizedBox(width: 6),
            Text(
              hr != null && hr.isFinite
                  ? '${hr.toStringAsFixed(0)} BPM'
                  : '--',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: _ChartCard(
            child: SizedBox(
              height: 110,
              child: RollingHrChart(
                rawHrStream: widget.rawHrStream,
                smoothedHrStream: widget.smoothedHrStream,
                initialRawData: _rawHrHistory,
                initialSmoothedData: _smoothedHrHistory,
                timestampExponent: widget.timestampExponent,
                timeWindow: 60,
                baseline: widget.calibration.latestResult?.baselineHeartRate,
                threshold: widget.calibration.latestResult?.triggerThreshold,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: AnimatedOpacity(
            duration: _reducedMotion
                ? Duration.zero
                : const Duration(milliseconds: 400),
            opacity: _relaxEndAvailable ? 1 : 0,
            child: IgnorePointer(
              ignoring: !_relaxEndAvailable,
              child: TextButton(
                onPressed: _onRelaxationComplete,
                child: Text(
                  'End relaxation',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWelcomeBack() {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        'Welcome back',
        style: theme.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
          color: theme.colorScheme.onSurface,
        ),
      ),
    );
  }

  Widget _buildRatingScreen({
    required String question,
    required List<String> options,
    required ValueChanged<String> onSelected,
  }) {
    final theme = Theme.of(context);
    return _ScreenFrame(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            question,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 32),
          for (final option in options) ...[
            _OptionButton(
              label: option,
              onPressed: () => onSelected(option),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  Widget _buildSummary() {
    final theme = Theme.of(context);
    final result = widget.calibration.latestResult;

    return _ScreenFrame(
      scrollable: true,
      footer: _PrimaryButton(
        label: 'Start Again',
        onPressed: _startAgain,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_rounded,
                size: 38,
                color: _accent,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Demo complete',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 28),
          _SummaryCard(
            rows: [
              (
                'Baseline',
                result != null
                    ? '${result.baselineHeartRate.toStringAsFixed(0)} BPM'
                    : '--'
              ),
              (
                'Peak HR',
                _peakHr != null
                    ? '${_peakHr!.toStringAsFixed(0)} BPM'
                    : '--'
              ),
              (
                'Trigger',
                switch (_triggerSource) {
                  DemoTriggerSource.automatic => 'Automatic',
                  DemoTriggerSource.demo => 'Demo',
                  null => '--',
                }
              ),
              ('Intensity', _intensityLevels[_selectedIntensityIndex]),
              ('Warmth rating', _warmthRating ?? '--'),
              ('Relaxation rating', _relaxationRating ?? '--'),
            ],
          ),
        ],
      ),
    );
  }

  // ── Shared pieces ──────────────────────────────────────────────────────────

  Widget _hrAndThresholdRow() {
    final hr = _currentHr;
    final threshold = widget.calibration.latestResult?.triggerThreshold;
    return Row(
      children: [
        Expanded(
          child: _StatTile(
            label: 'Heart rate',
            value: hr != null && hr.isFinite ? hr.toStringAsFixed(0) : '--',
            unit: 'BPM',
            color: _accent,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatTile(
            label: 'Trigger threshold',
            value: threshold != null ? threshold.toStringAsFixed(0) : '--',
            unit: 'BPM',
            color: const Color(0xFFFF8F00),
          ),
        ),
      ],
    );
  }
}

// ── Layout helpers ────────────────────────────────────────────────────────────

class _ScreenFrame extends StatelessWidget {
  final Widget child;
  final Widget? footer;
  final bool scrollable;

  const _ScreenFrame({
    required this.child,
    this.footer,
    this.scrollable = false,
  });

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
      child: child,
    );

    return Column(
      children: [
        Expanded(
          child: scrollable ? SingleChildScrollView(child: content) : content,
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: footer,
          ),
      ],
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const _PrimaryButton({required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF009682),
          foregroundColor: Colors.white,
          textStyle: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: Text(label),
      ),
    );
  }
}

class _OptionButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _OptionButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: theme.colorScheme.onSurface,
          side: BorderSide(color: theme.colorScheme.outlineVariant),
          textStyle: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w500,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: Text(label),
      ),
    );
  }
}

class _IntensityOption extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _IntensityOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const accent = Color(0xFF009682);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.08)
              : theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? accent : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 22,
              color: selected ? accent : theme.colorScheme.outlineVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool connected;
  final String statusText;
  final Widget? trailing;

  const _StatusRow({
    required this.icon,
    required this.label,
    required this.connected,
    required this.statusText,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor =
        connected ? const Color(0xFF009682) : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: connected ? const Color(0xFF009682) : Colors.grey.shade400,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            statusText,
            style: theme.textTheme.bodySmall?.copyWith(
              color: statusColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 4),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color color;

  const _StatTile({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              const SizedBox(width: 3),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  unit,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  final Widget child;

  const _ChartCard({required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final List<(String, String)> rows;

  const _SummaryCard({required this.rows});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 0.5,
                color: theme.colorScheme.outlineVariant,
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      rows[i].$1,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    rows[i].$2,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Survey results (visible only after leaving the demo flow) ────────────────

class SurveyResultsPage extends StatelessWidget {
  final List<DemoSurveyResult> results;

  const SurveyResultsPage({super.key, required this.results});

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('Survey results'),
      ),
      body: SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          itemCount: results.length,
          separatorBuilder: (_, __) => const SizedBox(height: 18),
          itemBuilder: (context, index) {
            final r = results[index];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 8),
                  child: Text(
                    'Run ${index + 1} · ${_fmtTime(r.timestamp)}',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _SummaryCard(
                  rows: [
                    ('Intensity', r.intensity),
                    (
                      'Trigger',
                      switch (r.triggerSource) {
                        DemoTriggerSource.automatic => 'Automatic',
                        DemoTriggerSource.demo => 'Demo',
                        null => '--',
                      }
                    ),
                    (
                      'Baseline',
                      r.baseline != null
                          ? '${r.baseline!.toStringAsFixed(0)} BPM'
                          : '--'
                    ),
                    (
                      'Peak HR',
                      r.peakHr != null
                          ? '${r.peakHr!.toStringAsFixed(0)} BPM'
                          : '--'
                    ),
                    ('Warmth rating', r.warmthRating ?? '--'),
                    ('Relaxation rating', r.relaxationRating ?? '--'),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ── Breathing pulse ───────────────────────────────────────────────────────────

class _BreathingPulse extends StatelessWidget {
  final AnimationController controller;
  final bool reducedMotion;
  final DateTime startTime;
  final double rampSeconds;
  final double startHz;
  final double endHz;

  const _BreathingPulse({
    required this.controller,
    required this.reducedMotion,
    required this.startTime,
    required this.rampSeconds,
    required this.startHz,
    required this.endHz,
  });

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF009682);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // The breath rate ramps linearly from startHz to endHz over
        // rampSeconds and then holds endHz; integrating the rate gives the
        // accumulated breath-cycle phase.
        final t =
            DateTime.now().difference(startTime).inMilliseconds / 1000.0;
        final double cycles;
        if (t < rampSeconds) {
          cycles = startHz * t + (endHz - startHz) * t * t / (2 * rampSeconds);
        } else {
          cycles = (startHz + endHz) * rampSeconds / 2 +
              endHz * (t - rampSeconds);
        }
        final frac = cycles - cycles.floorToDouble();
        final inhale = frac < 0.5;
        final phase = inhale ? frac / 0.5 : (frac - 0.5) / 0.5;
        final curved = Curves.easeInOut.transform(phase);
        final scale = reducedMotion
            ? 0.9
            : (inhale ? 0.52 + 0.53 * curved : 1.05 - 0.53 * curved);

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 230,
              height: 230,
              child: Center(
                child: Container(
                  width: 210 * scale,
                  height: 210 * scale,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        accent.withValues(alpha: 0.35),
                        accent.withValues(alpha: 0.10),
                      ],
                    ),
                    border: Border.all(
                      color: accent.withValues(alpha: 0.45),
                      width: 1.5,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Match your breathing to the pulse',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        );
      },
    );
  }
}

// ── Relaxation visual ─────────────────────────────────────────────────────────

class _RelaxationCircle extends StatelessWidget {
  final AnimationController controller;
  final bool reducedMotion;

  const _RelaxationCircle({
    required this.controller,
    required this.reducedMotion,
  });

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF009682);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // Gentle slow drift of the circle (one soft cycle per controller
        // repeat, ~6 s). Relaxation is open-ended, so there is no progress
        // indication.
        final drift =
            reducedMotion ? 0.0 : 0.05 * sin(controller.value * 2 * pi);
        return SizedBox(
          width: 240,
          height: 240,
          child: Center(
            child: Container(
              width: 190 * (1 + drift),
              height: 190 * (1 + drift),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    accent.withValues(alpha: 0.22),
                    accent.withValues(alpha: 0.05),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
