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
  final String? preferredLevel;

  const DemoSurveyResult({
    required this.timestamp,
    required this.intensity,
    this.baseline,
    this.peakHr,
    this.triggerSource,
    this.warmthRating,
    this.relaxationRating,
    this.preferredLevel,
  });
}

enum _DemoStep {
  ready,
  baseline,
  activationIntro,
  breathing,
  monitoring,
  triggerConfirm,
  relaxationIntro,
  relaxationRunning,
  welcomeBack,
  warmthRating,
  relaxationRating,
  comparisonOffer,
  comparisonRunning,
  preferenceRating,
  summary,
}

enum _ComparisonPhase { idle, heating, cooldown }

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

  // Guided breathing ramps from 30 breaths/min up to 60 breaths/min over
  // the breathing phase.
  static const double _breathStartHz = 0.5;
  static const double _breathEndHz = 1.0;
  static const Duration _breathingMaxDuration = Duration(seconds: 10);
  static const Duration _demoTriggerRevealDelay = Duration(seconds: 18);
  static const Duration _relaxationDuration = Duration(seconds: 25);
  static const Duration _welcomeBackDuration = Duration(milliseconds: 1800);
  static const int _comparisonHeatSeconds = 10;
  static const int _comparisonCooldownSeconds = 6;

  static const List<String> _comparisonLevels = ['Low', 'Medium', 'High'];
  static const List<int> _comparisonPwm = [_pwmLow, _pwmMedium, _pwmHigh];

  _DemoStep _step = _DemoStep.ready;

  // Live signal state
  StreamSubscription<double?>? _hrSub;
  StreamSubscription<PpgSignalQuality>? _qualitySub;
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
  String? _preferredLevel;
  bool _demoTriggerAvailable = false;
  bool _recalibrateOnBaselineEntry = false;
  int _selectedIntensityIndex = 1;
  bool _resultSaved = false;

  // Comparison state
  int _comparisonLevel = 0;
  _ComparisonPhase _comparisonPhase = _ComparisonPhase.idle;
  int _comparisonRemaining = 0;

  // Timers & animation
  Timer? _stepTimer;
  Timer? _demoRevealTimer;
  Timer? _comparisonTimer;
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
  }

  @override
  void dispose() {
    _hrSub?.cancel();
    _qualitySub?.cancel();
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
    _comparisonTimer?.cancel();
    _comparisonTimer = null;
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
    // as the HR-based autopilot mode) — never waits for the breathing timer.
    if (!_thermalStarted &&
        (_step == _DemoStep.breathing || _step == _DemoStep.monitoring)) {
      final result = widget.calibration.latestResult;
      if (result != null && bpm > result.triggerThreshold) {
        _onAutomaticTrigger();
        return;
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
    unawaited(_setPwm(_comparisonPwm[_selectedIntensityIndex]));
  }

  // ── State machine transitions ──────────────────────────────────────────────

  void _goTo(_DemoStep step) {
    _cancelTimers();
    _breathingController?.stop();
    setState(() => _step = step);

    switch (step) {
      case _DemoStep.baseline:
        _enterBaseline();
      case _DemoStep.breathing:
        _enterBreathing();
      case _DemoStep.monitoring:
        _enterMonitoring();
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
        intensity: _comparisonLevels[_selectedIntensityIndex],
        baseline: widget.calibration.latestResult?.baselineHeartRate,
        peakHr: _peakHr,
        triggerSource: _triggerSource,
        warmthRating: _warmthRating,
        relaxationRating: _relaxationRating,
        preferredLevel: _preferredLevel,
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

  void _enterBaseline() {
    final calibration = widget.calibration;
    if (_recalibrateOnBaselineEntry || calibration.latestResult == null) {
      _recalibrateOnBaselineEntry = false;
      // stop() before start() so the existing subscriptions are re-created
      // cleanly for the next participant.
      calibration.stop();
      calibration.start(
        heartRateStream: widget.heartRateStream,
        signalQualityStream: widget.signalQualityStream,
      );
    }
    _uiTick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  void _enterBreathing() {
    _trackPeak = true;
    _breathingController?.dispose();
    // One controller spans the whole breathing phase; the pulse widget derives
    // the accelerating breath cycle from its progress.
    _breathingController = AnimationController(
      vsync: this,
      duration: _breathingMaxDuration,
    )
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          // Breathing phase over without a trigger → keep monitoring real HR.
          _goTo(_DemoStep.monitoring);
        }
      })
      ..forward();
  }

  void _enterMonitoring() {
    _demoTriggerAvailable = false;
    _demoRevealTimer = Timer(_demoTriggerRevealDelay, () {
      if (mounted) setState(() => _demoTriggerAvailable = true);
    });
  }

  void _onAutomaticTrigger() {
    // Immediate: stop the breathing visual, cancel remaining timers and start
    // the thermal feedback through the existing safe control path.
    _cancelTimers();
    _breathingController?.stop();
    _startThermalFeedback(DemoTriggerSource.automatic);
    if (mounted) setState(() => _step = _DemoStep.triggerConfirm);
  }

  void _onDemoTrigger() {
    // Does not change or fake any HR value — only starts the same safe
    // thermal pathway and records the source as "demo".
    _cancelTimers();
    _startThermalFeedback(DemoTriggerSource.demo);
    _goTo(_DemoStep.triggerConfirm);
  }

  void _enterRelaxation() {
    _relaxationController?.dispose();
    _relaxationController = AnimationController(
      vsync: this,
      duration: _relaxationDuration,
    )
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _onRelaxationComplete();
        }
      })
      ..forward();
  }

  void _onRelaxationComplete() {
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
    _goTo(_DemoStep.comparisonOffer);
  }

  void _selectPreferredLevel(String value) {
    unawaited(HapticFeedback.selectionClick());
    _preferredLevel = value;
    _goTo(_DemoStep.summary);
  }

  // ── Intensity comparison ───────────────────────────────────────────────────

  void _startComparison() {
    _comparisonLevel = 0;
    _comparisonPhase = _ComparisonPhase.idle;
    _goTo(_DemoStep.comparisonRunning);
  }

  void _startComparisonLevel() {
    // Explicit start per level; no overlapping or stacked heating commands.
    if (_comparisonPhase != _ComparisonPhase.idle || _currentPwm != 0) return;
    setState(() {
      _comparisonPhase = _ComparisonPhase.heating;
      _comparisonRemaining = _comparisonHeatSeconds;
    });
    unawaited(_setPwm(_comparisonPwm[_comparisonLevel]));
    _comparisonTimer?.cancel();
    _comparisonTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _comparisonRemaining--);
      if (_comparisonRemaining > 0) return;
      if (_comparisonPhase == _ComparisonPhase.heating) {
        // Level done → full stop, then cooldown before the next level.
        unawaited(_setPwm(0));
        setState(() {
          _comparisonPhase = _ComparisonPhase.cooldown;
          _comparisonRemaining = _comparisonCooldownSeconds;
        });
      } else {
        t.cancel();
        if (_comparisonLevel < _comparisonLevels.length - 1) {
          setState(() {
            _comparisonLevel++;
            _comparisonPhase = _ComparisonPhase.idle;
          });
        } else {
          _goTo(_DemoStep.preferenceRating);
        }
      }
    });
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
      _preferredLevel = null;
      _peakHr = null;
      _trackPeak = false;
      _demoTriggerAvailable = false;
      _resultSaved = false;
      _comparisonLevel = 0;
      _comparisonPhase = _ComparisonPhase.idle;
      // Next participant gets a fresh personal baseline; BLE connections
      // are intentionally preserved.
      _recalibrateOnBaselineEntry = true;
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final body = switch (_step) {
      _DemoStep.ready => _buildReady(),
      _DemoStep.baseline => _buildBaseline(),
      _DemoStep.activationIntro => _buildActivationIntro(),
      _DemoStep.breathing => _buildBreathing(),
      _DemoStep.monitoring => _buildMonitoring(),
      _DemoStep.triggerConfirm => _buildTriggerConfirm(),
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
      _DemoStep.comparisonOffer => _buildComparisonOffer(),
      _DemoStep.comparisonRunning => _buildComparisonRunning(),
      _DemoStep.preferenceRating => _buildRatingScreen(
          question: 'Which warmth level did you prefer?',
          options: const ['Low', 'Medium', 'High', 'No preference'],
          onSelected: _selectPreferredLevel,
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
        onPressed: _hrSignalActive ? () => _goTo(_DemoStep.baseline) : null,
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
          const SizedBox(height: 28),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Text(
              'Warmth intensity',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (var i = 0; i < _comparisonLevels.length; i++) ...[
            _IntensityOption(
              label: _comparisonLevels[i],
              selected: _selectedIntensityIndex == i,
              onTap: () {
                unawaited(HapticFeedback.selectionClick());
                setState(() => _selectedIntensityIndex = i);
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
                    _recalibrateOnBaselineEntry = true;
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _hrAndThresholdRow(),
          Expanded(
            child: Center(
              child: _BreathingPulse(
                controller: _breathingController!,
                reducedMotion: _reducedMotion,
                totalSeconds: _breathingMaxDuration.inSeconds.toDouble(),
                startHz: _breathStartHz,
                endHz: _breathEndHz,
              ),
            ),
          ),
          _ChartCard(
            child: SizedBox(
              height: 100,
              child: RollingHrChart(
                rawHrStream: widget.rawHrStream,
                smoothedHrStream: widget.smoothedHrStream,
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

  Widget _buildMonitoring() {
    final theme = Theme.of(context);
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
          const SizedBox(height: 32),
          Text(
            'You can breathe normally again',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Calmables keeps monitoring your heart rate.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                valueColor: AlwaysStoppedAnimation<Color>(_accent),
              ),
            ),
          ),
          const Spacer(),
          _ChartCard(
            child: SizedBox(
              height: 120,
              child: RollingHrChart(
                rawHrStream: widget.rawHrStream,
                smoothedHrStream: widget.smoothedHrStream,
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

  Widget _buildTriggerConfirm() {
    final theme = Theme.of(context);
    final isAutomatic = _triggerSource == DemoTriggerSource.automatic;
    final hr = _currentHr;
    final threshold = widget.calibration.latestResult?.triggerThreshold;

    return _ScreenFrame(
      footer: _PrimaryButton(
        label: 'Continue',
        onPressed: () => _goTo(_DemoStep.relaxationIntro),
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
              child: Icon(
                isAutomatic
                    ? Icons.monitor_heart_rounded
                    : Icons.play_circle_rounded,
                size: 36,
                color: _accent,
              ),
            ),
          ),
          const SizedBox(height: 28),
          Text(
            isAutomatic
                ? 'Heart rate threshold reached'
                : 'Thermal feedback started',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            isAutomatic
                ? 'Calmables detected that your heart rate reached your '
                    'personal activation threshold and started the thermal '
                    'feedback.'
                : 'Demo mode started the thermal feedback so you can '
                    'continue the experience.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 32),
          if (isAutomatic) ...[
            _FlowStep(
              icon: Icons.favorite_rounded,
              label: 'Current HR',
              value: hr != null && hr.isFinite
                  ? '${hr.toStringAsFixed(0)} BPM'
                  : '--',
            ),
            const _FlowArrow(),
            _FlowStep(
              icon: Icons.flag_rounded,
              label: 'Threshold reached',
              value: threshold != null
                  ? '${threshold.toStringAsFixed(0)} BPM'
                  : '--',
            ),
            const _FlowArrow(),
            const _FlowStep(
              icon: Icons.local_fire_department_rounded,
              label: 'Thermal feedback',
              value: 'Active',
            ),
          ] else
            const _FlowStep(
              icon: Icons.local_fire_department_rounded,
              label: 'Thermal feedback',
              value: 'Active',
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
    final controller = _relaxationController;
    return Center(
      child: controller == null
          ? const SizedBox.shrink()
          : _RelaxationCircle(
              controller: controller,
              reducedMotion: _reducedMotion,
            ),
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

  Widget _buildComparisonOffer() {
    final theme = Theme.of(context);
    return _ScreenFrame(
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PrimaryButton(
            label: 'Start comparison',
            onPressed: _startComparison,
          ),
          TextButton(
            onPressed: () => _goTo(_DemoStep.summary),
            child: const Text('Skip'),
          ),
        ],
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
              child: const Icon(Icons.tune_rounded, size: 36, color: _accent),
            ),
          ),
          const SizedBox(height: 28),
          Text(
            'Compare warmth levels',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Try a few short thermal levels and choose which feels most '
            'comfortable.',
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

  Widget _buildComparisonRunning() {
    final theme = Theme.of(context);
    final level = _comparisonLevels[_comparisonLevel];
    final isHeating = _comparisonPhase == _ComparisonPhase.heating;
    final isCooldown = _comparisonPhase == _ComparisonPhase.cooldown;

    return _ScreenFrame(
      footer: _PrimaryButton(
        label: 'Start $level warmth',
        onPressed:
            _comparisonPhase == _ComparisonPhase.idle && _currentPwm == 0
                ? _startComparisonLevel
                : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < _comparisonLevels.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Container(
                  width: i == _comparisonLevel ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i <= _comparisonLevel
                        ? _accent
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 28),
          Text(
            '$level warmth',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            isHeating
                ? 'Notice how this level feels.'
                : isCooldown
                    ? 'Cooling down before the next level.'
                    : 'Tap start when you are ready.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 36),
          Center(
            child: SizedBox(
              width: 120,
              height: 120,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 120,
                    height: 120,
                    child: CircularProgressIndicator(
                      value: isHeating
                          ? _comparisonRemaining / _comparisonHeatSeconds
                          : isCooldown
                              ? _comparisonRemaining /
                                  _comparisonCooldownSeconds
                              : 0,
                      strokeWidth: 5,
                      strokeCap: StrokeCap.round,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        isCooldown ? const Color(0xFF64B5F6) : _accent,
                      ),
                    ),
                  ),
                  Icon(
                    isHeating
                        ? Icons.local_fire_department_rounded
                        : isCooldown
                            ? Icons.ac_unit_rounded
                            : Icons.thermostat_rounded,
                    size: 40,
                    color: isCooldown ? const Color(0xFF64B5F6) : _accent,
                  ),
                ],
              ),
            ),
          ),
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
              ('Intensity', _comparisonLevels[_selectedIntensityIndex]),
              ('Warmth rating', _warmthRating ?? '--'),
              ('Relaxation rating', _relaxationRating ?? '--'),
              if (_preferredLevel != null)
                ('Preferred warmth level', _preferredLevel!),
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

class _FlowStep extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _FlowStep({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: const Color(0xFF009682)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _FlowArrow extends StatelessWidget {
  const _FlowArrow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Icon(
        Icons.arrow_downward_rounded,
        size: 16,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
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
                    if (r.preferredLevel != null)
                      ('Preferred warmth level', r.preferredLevel!),
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
  final double totalSeconds;
  final double startHz;
  final double endHz;

  const _BreathingPulse({
    required this.controller,
    required this.reducedMotion,
    required this.totalSeconds,
    required this.startHz,
    required this.endHz,
  });

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF009682);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // The breath rate ramps linearly from startHz to endHz over the
        // phase; integrating gives the accumulated breath-cycle phase.
        final t = controller.value * totalSeconds;
        final cycles = startHz * t + (endHz - startHz) * t * t / (2 * totalSeconds);
        final frac = cycles - cycles.floorToDouble();
        final inhale = frac < 0.5;
        final phase = inhale ? frac / 0.5 : (frac - 0.5) / 0.5;
        final curved = Curves.easeInOut.transform(phase);
        final scale = reducedMotion
            ? 0.9
            : (inhale ? 0.72 + 0.28 * curved : 1.0 - 0.28 * curved);

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 210,
              height: 210,
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
                  child: Center(
                    child: Text(
                      inhale ? 'In' : 'Out',
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF00695C),
                            letterSpacing: -0.3,
                          ),
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
        final progress = controller.value;
        // Gentle slow drift of the inner circle (one soft cycle ~6 s).
        final drift = reducedMotion
            ? 0.0
            : 0.04 * sin(progress * 2 * pi * 4);
        return SizedBox(
          width: 240,
          height: 240,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Subtle progress ring instead of a countdown.
              SizedBox(
                width: 240,
                height: 240,
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 2.5,
                  strokeCap: StrokeCap.round,
                  backgroundColor: accent.withValues(alpha: 0.10),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    accent.withValues(alpha: 0.35),
                  ),
                ),
              ),
              Container(
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
            ],
          ),
        );
      },
    );
  }
}
