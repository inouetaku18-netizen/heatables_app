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

  /// Agreement on a 1–7 scale (1 = Strongly Disagree, 7 = Strongly Agree).
  final int? relaxationAgreement;
  final int? usageAgreement;

  const DemoSurveyResult({
    required this.timestamp,
    required this.intensity,
    this.baseline,
    this.peakHr,
    this.triggerSource,
    this.relaxationAgreement,
    this.usageAgreement,
  });
}

enum _DemoStep {
  ready,
  intensitySelect,
  baseline,
  breathing,
  relaxationRunning,
  welcomeBack,
  relaxationStatement,
  usageStatement,
  summary,
}

/// Number of points on the agreement scale (1 = Strongly Disagree).
const int _likertPoints = 7;

String _likertLabel(int value) => switch (value) {
      1 => 'Strongly Disagree',
      7 => 'Strongly Agree',
      _ => '',
    };

/// Compact "5 / 7" rendering for summaries, with the anchor label if any.
String _agreementText(int? value) {
  if (value == null) return '--';
  final label = _likertLabel(value);
  return label.isEmpty ? '$value / 7' : '$value / 7 · $label';
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

  // Intensity is a free 0–255 PWM value like on the main Calmables page.
  // No new safety parameters — every write goes through the same central
  // BLE path as manual control.

  // Guided breathing ramps from 30 breaths/min up to 50 breaths/min over
  // the breathing phase.
  static const double _breathStartHz = 30 / 60;
  static const double _breathEndHz = 50 / 60;
  static const Duration _breathRampDuration = Duration(seconds: 10);
  static const Duration _demoTriggerRevealDelay = Duration(seconds: 20);
  static const Duration _relaxEndOptionDelay = Duration(seconds: 30);
  static const Duration _relaxMinDuration = Duration(seconds: 25);


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
  int? _relaxationAgreement;
  int? _usageAgreement;
  bool _demoTriggerAvailable = false;
  bool _recalibrateOnNextRun = false;
  int _demoPwm = 130;
  bool _previewOn = false;
  bool _resultSaved = false;
  int _aboveThresholdCount = 0;
  DateTime? _breathingStartedAt;

  // Relaxation: runs at least _relaxMinDuration; after that, heating stays
  // active until the (smoothed) HR falls below the deactivation threshold —
  // the same hysteresis value the HR-based autopilot mode uses.
  DateTime? _relaxationStartedAt;
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
    // deactivation threshold (same hysteresis as the autopilot mode) —
    // but never before the minimum relaxation duration has passed.
    if (_step == _DemoStep.relaxationRunning) {
      final result = widget.calibration.latestResult;
      final startedAt = _relaxationStartedAt;
      if (result != null &&
          startedAt != null &&
          DateTime.now().difference(startedAt) >= _relaxMinDuration) {
        final deactivateThreshold = result.baselineHeartRate +
            0.2 * (result.triggerThreshold - result.baselineHeartRate);
        if (bpm < deactivateThreshold) {
          _belowThresholdCount++;
          if (_belowThresholdCount >= _triggerDebounceSamples) {
            _onRelaxationComplete();
            return;
          }
        } else {
          _belowThresholdCount = 0;
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
    unawaited(_setPwm(_demoPwm));
  }

  String _intensityDescription() => '${_warmthLabel(_demoPwm)} · $_demoPwm';

  // ── State machine transitions ──────────────────────────────────────────────

  void _goTo(_DemoStep step) {
    _cancelTimers();
    // Both visuals repeat indefinitely; stop them when their screen is left
    // so no ticker keeps running for the rest of the session.
    _breathingController?.stop();
    _relaxationController?.stop();
    setState(() => _step = step);

    switch (step) {
      case _DemoStep.intensitySelect:
        // Preview heating starts right away at the current slider value.
        // Only the HR signal itself warms up in the background here; the
        // baseline aggregation starts when the user continues.
        _previewOn = true;
        unawaited(_setPwm(_demoPwm));
      case _DemoStep.baseline:
        _enterBaseline();
      case _DemoStep.breathing:
        _enterBreathing();
      case _DemoStep.relaxationRunning:
        _enterRelaxation();
      case _DemoStep.welcomeBack:
        // Vibrate repeatedly until the user confirms they are back.
        unawaited(HapticFeedback.vibrate());
        _stepTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) {
          unawaited(HapticFeedback.vibrate());
        });
      case _DemoStep.summary:
        _saveSurveyResult();
      default:
        break;
    }
  }

  void _saveSurveyResult() {
    if (_resultSaved) return;
    if (_relaxationAgreement == null && _usageAgreement == null) return;
    _resultSaved = true;
    LiveDemoPage.sessionResults.add(
      DemoSurveyResult(
        timestamp: DateTime.now(),
        intensity: _intensityDescription(),
        baseline: widget.calibration.latestResult?.baselineHeartRate,
        peakHr: _peakHr,
        triggerSource: _triggerSource,
        relaxationAgreement: _relaxationAgreement,
        usageAgreement: _usageAgreement,
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

  /// Starts (or restarts) the baseline aggregation if needed. The HR signal
  /// itself already streams from the moment the demo page opens; only the
  /// 30-second aggregation window starts here.
  void _startCalibrationIfNeeded() {
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
    // The aggregation window intentionally starts only now — when the user
    // has continued to the baseline step — not while selecting intensity.
    _startCalibrationIfNeeded();
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
    if (!mounted) return;
    _goTo(_DemoStep.relaxationRunning);
  }

  void _onDemoTrigger() {
    // Does not change or fake any HR value — only starts the same safe
    // thermal pathway and records the source as "demo".
    _cancelTimers();
    _startThermalFeedback(DemoTriggerSource.demo);
    _goTo(_DemoStep.relaxationRunning);
  }

  void _enterRelaxation() {
    _relaxationStartedAt = DateTime.now();
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
    _goTo(_DemoStep.welcomeBack);
  }

  // ── Ratings ────────────────────────────────────────────────────────────────

  void _selectRelaxationStatement(int value) {
    unawaited(HapticFeedback.selectionClick());
    _relaxationAgreement = value;
    _goTo(_DemoStep.usageStatement);
  }

  void _selectUsageStatement(int value) {
    unawaited(HapticFeedback.selectionClick());
    _usageAgreement = value;
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
      _relaxationAgreement = null;
      _usageAgreement = null;
      _peakHr = null;
      _trackPeak = false;
      _demoTriggerAvailable = false;
      _previewOn = false;
      _resultSaved = false;
      _aboveThresholdCount = 0;
      _breathingStartedAt = null;
      _relaxationStartedAt = null;
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
      _DemoStep.breathing => _buildBreathing(),
      _DemoStep.relaxationRunning => _buildRelaxationRunning(),
      _DemoStep.welcomeBack => _buildWelcomeBack(),
      _DemoStep.relaxationStatement => _buildLikertScreen(
          number: 1,
          statement: 'The device helped me feel more relaxed.',
          onSelected: _selectRelaxationStatement,
        ),
      _DemoStep.usageStatement => _buildLikertScreen(
          number: 2,
          statement: 'I would use this device during stressful days '
              'in private.',
          onSelected: _selectUsageStatement,
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
        // The bar stays mounted on every screen so the body origin — and with
        // it every shared layout anchor — never shifts between screens. The
        // quiet screens simply leave it empty.
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          automaticallyImplyLeading: false,
          leading: isQuiet
              ? null
              : IconButton(
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
    final calmablesConnected = widget.isCalmablesConnected();

    return _ScreenFrame(
      header: const _ScreenHeader(
        icon: Icons.spa_rounded,
        title: _kReadyTitle,
        subtitle: _kReadyDescription,
      ),
      scrollContent: true,
      primaryAction: _PrimaryButton(
        label: 'Start Demo',
        onPressed:
            _hrSignalActive ? () => _goTo(_DemoStep.intensitySelect) : null,
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
      header: const _ScreenHeader(
        icon: Icons.thermostat_rounded,
        title: _kIntensityTitle,
        subtitle: _kIntensityDescription,
      ),
      scrollContent: true,
      primaryAction: _PrimaryButton(
        label: 'Continue',
        onPressed: () {
          // Always switch the preview heating off before moving on.
          _previewOn = false;
          unawaited(_setPwm(0));
          _goTo(_DemoStep.baseline);
        },
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            decoration: BoxDecoration(
              color: _panelColor(theme),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Warmth',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Row(
                      children: [
                        Text(
                          _previewOn ? 'ON' : 'OFF',
                          style: TextStyle(
                            color: _previewOn ? _accent : Colors.grey,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Switch(
                          value: _previewOn,
                          activeThumbColor: _accent,
                          activeTrackColor: _accent.withValues(alpha: 0.3),
                          onChanged: (v) {
                            setState(() => _previewOn = v);
                            unawaited(_setPwm(v ? _demoPwm : 0));
                          },
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Intensity',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: Colors.grey.shade600),
                    ),
                    Text(
                      _warmthLabel(_demoPwm),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: _pwmColor(_demoPwm),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4.0,
                    trackShape: const _GradientSliderTrackShape(),
                    thumbColor: _pwmColor(_demoPwm),
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    overlayColor: _pwmColor(_demoPwm).withValues(alpha: 0.2),
                    showValueIndicator: ShowValueIndicator.onlyForDiscrete,
                    valueIndicatorColor: Colors.grey.shade700,
                    valueIndicatorTextStyle: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  child: Slider(
                    value: _demoPwm.toDouble(),
                    min: 0,
                    max: 255,
                    divisions: 255,
                    label: _demoPwm.toString(),
                    onChanged: (v) {
                      setState(() => _demoPwm = v.round());
                      if (_previewOn) {
                        unawaited(_setPwm(_demoPwm));
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
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

    return _ScreenFrame(
      header: const _ScreenHeader(
        icon: Icons.favorite_rounded,
        title: _kBaselineTitle,
        subtitle: _kBaselineDescription,
      ),
      scrollContent: true,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Same KPI row position and size as on the activation screen.
          _kpiRow(
            leadingLabel: 'Baseline',
            leadingValue: result != null
                ? result.baselineHeartRate.toStringAsFixed(0)
                : '--',
            trailingValue: result != null
                ? result.triggerThreshold.toStringAsFixed(0)
                : '--',
          ),
          const SizedBox(height: 20),
          _currentHeartRateBlock(),
          SizedBox(
            height: 44,
            child: isCalibrating
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: calibration.progressFraction,
                          minHeight: 4,
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHighest,
                          valueColor:
                              const AlwaysStoppedAnimation<Color>(_accent),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Measuring your resting baseline…',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  )
                : null,
          ),
        ],
      ),
      chart: _hrChartCard(),
      primaryAction: _PrimaryButton(
        label: 'Continue',
        onPressed: ready ? () => _goTo(_DemoStep.breathing) : null,
      ),
      secondaryAction: TextButton(
        onPressed: isCalibrating
            ? null
            : () {
                _recalibrateOnNextRun = true;
                _goTo(_DemoStep.baseline);
              },
        style: TextButton.styleFrom(
          foregroundColor: theme.colorScheme.onSurfaceVariant,
        ),
        child: const Text('Restart measurement'),
      ),
    );
  }

  /// Large live heart rate reading used on the baseline screen.
  Widget _currentHeartRateBlock() {
    final theme = Theme.of(context);
    final hr = _currentHr;
    return Center(
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
    );
  }

  Widget _buildBreathing() {
    return _ScreenFrame(
      header: const _ScreenHeader(
        icon: Icons.air_rounded,
        title: _kActivationTitle,
        subtitle: _kActivationDescription,
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _liveHrKpiRow(),
          Expanded(
            child: Center(
              child: LayoutBuilder(
                builder: (context, constraints) => _BreathingPulse(
                  controller: _breathingController!,
                  reducedMotion: _reducedMotion,
                  startTime: _breathingStartedAt ?? DateTime.now(),
                  rampSeconds: _breathRampDuration.inSeconds.toDouble(),
                  startHz: _breathStartHz,
                  endHz: _breathEndHz,
                  diameter: _circleDiameter(constraints),
                ),
              ),
            ),
          ),
        ],
      ),
      chart: _hrChartCard(),
      primaryAction: AnimatedOpacity(
        duration:
            _reducedMotion ? Duration.zero : const Duration(milliseconds: 400),
        opacity: _demoTriggerAvailable ? 1 : 0,
        child: IgnorePointer(
          ignoring: !_demoTriggerAvailable,
          child: _PrimaryButton(
            label: 'Continue with Demo Trigger',
            onPressed: _onDemoTrigger,
          ),
        ),
      ),
    );
  }

  /// Largest circle that still fits the space left over for the visual, so
  /// the screens stay overflow-free on small phones.
  double _circleDiameter(BoxConstraints constraints) {
    final available = min(constraints.maxHeight, constraints.maxWidth);
    return available.isFinite ? available.clamp(0.0, 230.0) : 230.0;
  }

  Widget _buildRelaxationRunning() {
    final theme = Theme.of(context);
    final controller = _relaxationController;
    final hr = _currentHr;

    return _ScreenFrame(
      header: const _ScreenHeader(
        icon: Icons.self_improvement_rounded,
        title: _kRelaxationTitle,
        subtitle: _kRelaxationDescription,
      ),
      content: Column(
        children: [
          Expanded(
            child: Center(
              child: controller == null
                  ? const SizedBox.shrink()
                  : LayoutBuilder(
                      builder: (context, constraints) => _RelaxationCircle(
                        controller: controller,
                        reducedMotion: _reducedMotion,
                        diameter: _circleDiameter(constraints),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.favorite_rounded, size: 16, color: _accent),
              const SizedBox(width: 6),
              Text(
                hr != null && hr.isFinite ? '${hr.toStringAsFixed(0)} BPM' : '--',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
      chart: _hrChartCard(),
      secondaryAction: AnimatedOpacity(
        duration:
            _reducedMotion ? Duration.zero : const Duration(milliseconds: 400),
        opacity: _relaxEndAvailable ? 1 : 0,
        child: IgnorePointer(
          ignoring: !_relaxEndAvailable,
          child: TextButton(
            onPressed: _onRelaxationComplete,
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.onSurfaceVariant,
            ),
            child: const Text(
              'End relaxation',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWelcomeBack() {
    return _ScreenFrame(
      header: const _ScreenHeader(
        icon: Icons.waving_hand_rounded,
        title: _kWelcomeBackTitle,
      ),
      primaryAction: _PrimaryButton(
        label: "I'm back",
        onPressed: () => _goTo(_DemoStep.relaxationStatement),
      ),
    );
  }

  Widget _buildLikertScreen({
    required int number,
    required String statement,
    required ValueChanged<int> onSelected,
  }) {
    final theme = Theme.of(context);
    // The survey pages carry no icon, chart or primary button, but keep the
    // shared horizontal padding and bottom margin.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        _kScreenHPadding,
        12,
        _kScreenHPadding,
        _kFooterBottomPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$number. $statement',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 24),
          for (var value = 1; value <= _likertPoints; value++) ...[
            _LikertOption(
              value: value,
              label: _likertLabel(value),
              onTap: () => onSelected(value),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildSummary() {
    final result = widget.calibration.latestResult;

    return _ScreenFrame(
      header: const _ScreenHeader(
        icon: Icons.check_rounded,
        title: _kSummaryTitle,
      ),
      scrollContent: true,
      primaryAction: _PrimaryButton(
        label: 'Start Again',
        onPressed: _startAgain,
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
              ('Intensity', _intensityDescription()),
              ('Felt more relaxed', _agreementText(_relaxationAgreement)),
              ('Would use in private', _agreementText(_usageAgreement)),
            ],
          ),
        ],
      ),
    );
  }

  // ── Shared pieces ──────────────────────────────────────────────────────────

  /// Two-card KPI row — identical size, spacing and position on every screen
  /// that shows one.
  Widget _kpiRow({
    required String leadingLabel,
    required String leadingValue,
    required String trailingValue,
  }) {
    return Row(
      children: [
        Expanded(
          child: _StatTile(
            label: leadingLabel,
            value: leadingValue,
            unit: 'BPM',
            color: _accent,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatTile(
            label: 'Trigger threshold',
            value: trailingValue,
            unit: 'BPM',
            color: const Color(0xFFFF8F00),
          ),
        ),
      ],
    );
  }

  Widget _liveHrKpiRow() {
    final hr = _currentHr;
    final threshold = widget.calibration.latestResult?.triggerThreshold;
    return _kpiRow(
      leadingLabel: 'Heart rate',
      leadingValue: hr != null && hr.isFinite ? hr.toStringAsFixed(0) : '--',
      trailingValue: threshold != null ? threshold.toStringAsFixed(0) : '--',
    );
  }

  /// Live HR chart — same width and height wherever it appears.
  Widget _hrChartCard() {
    return _ChartCard(
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
    );
  }
}

// ── Layout helpers ────────────────────────────────────────────────────────────

// ── Shared screen scaffold ────────────────────────────────────────────────────
//
// Every demo screen is built from the same vertical slots so that the icon,
// heading, description, chart and primary button sit at identical coordinates
// on all screens. Slots keep their reserved height even when a screen leaves
// them empty, so switching screens never shifts a shared anchor.

const double _kScreenHPadding = 24;
const double _kHeaderTopGap = 8;
const double _kIconCircleSize = 64;
const double _kIconToTitle = 16;
const double _kTitleToDescription = 8;
const double _kHeaderToContent = 20;
const double _kContentToChart = 16;
const double _kChartSlotHeight = 116;
const double _kMinChartSlotHeight = 60;
const double _kMinContentHeight = 100;
const double _kChartToFooter = 14;
const double _kPrimaryButtonHeight = 54;
const double _kPrimaryToSecondary = 4;
const double _kSecondarySlotHeight = 40;
const double _kFooterBottomPadding = 16;

// Single source of truth for the header copy. The reserved header height is
// measured from these strings, so the content below always starts at the same
// offset no matter which screen is showing.
const String _kReadyTitle = 'Calmables';
const String _kReadyDescription =
    'Thermal biofeedback for short moments of recovery';
const String _kIntensityTitle = 'Stimulation intensity';
const String _kIntensityDescription =
    'Adjust the intensity used for the thermal feedback. '
    'You can feel it while adjusting.';
const String _kBaselineTitle = 'Baseline measurement';
const String _kBaselineDescription =
    'Calmables uses your personal resting heart rate as a baseline and '
    'derives the activation threshold that starts the thermal feedback.';
const String _kActivationTitle = 'Brief activation';
const String _kActivationDescription =
    'Follow the pulse and match your breathing to its rhythm. '
    'Keep your breathing light and comfortable.';
const String _kRelaxationTitle = 'Relaxation';
const String _kRelaxationDescription =
    'Take a moment to notice the stimulation. Feel free to close your eyes '
    "and focus on the sensation. We'll gently bring you back in a few moments.";
const String _kWelcomeBackTitle = 'Welcome back.';
const String _kSummaryTitle = 'Demo complete';

const List<String> _kHeaderTitles = [
  _kReadyTitle,
  _kIntensityTitle,
  _kBaselineTitle,
  _kActivationTitle,
  _kRelaxationTitle,
  _kWelcomeBackTitle,
  _kSummaryTitle,
];

// Only the screens whose content must line up (the KPI cards on the baseline
// and activation screens) drive the reserved header height. Screens without
// aligned content — such as relaxation, whose description is the longest —
// simply extend into their own flexible content area; their icon, heading and
// description still start at the shared offsets.
const List<String> _kHeaderDescriptions = [
  _kBaselineDescription,
  _kActivationDescription,
];

TextStyle? _headerTitleStyle(ThemeData theme) =>
    theme.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
    );

TextStyle? _headerDescriptionStyle(ThemeData theme) =>
    theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.4,
    );

/// Reserved height of the header block, measured from the longest title and
/// the longest description across all screens, so the content area below it
/// starts at the same offset everywhere — also under Dynamic Type.
double _headerSlotHeight(BuildContext context, double maxWidth) {
  final theme = Theme.of(context);
  final scaler = MediaQuery.textScalerOf(context);

  double measure(String text, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      textScaler: scaler,
    )..layout(maxWidth: maxWidth);
    return painter.height;
  }

  var titleHeight = 0.0;
  for (final title in _kHeaderTitles) {
    titleHeight = max(titleHeight, measure(title, _headerTitleStyle(theme)));
  }
  var descriptionHeight = 0.0;
  for (final description in _kHeaderDescriptions) {
    descriptionHeight = max(
      descriptionHeight,
      measure(description, _headerDescriptionStyle(theme)),
    );
  }

  return _kIconCircleSize +
      _kIconToTitle +
      titleHeight +
      _kTitleToDescription +
      descriptionHeight;
}

class _ScreenFrame extends StatelessWidget {
  /// Icon + heading + description; always occupies the same reserved height.
  final _ScreenHeader header;

  /// Flexible middle area. Longer content scrolls inside its slot instead of
  /// pushing the chart or the button out of place.
  final Widget? content;
  final bool scrollContent;

  /// Chart slot — fixed height, identical on every screen that uses one.
  final Widget? chart;

  /// Bottom slots. Both keep their height when a screen has no action, so the
  /// primary button never moves.
  final Widget? primaryAction;
  final Widget? secondaryAction;

  const _ScreenFrame({
    required this.header,
    this.content,
    this.scrollContent = false,
    this.chart,
    this.primaryAction,
    this.secondaryAction,
  });

  @override
  Widget build(BuildContext context) {
    final contentSlot = content ?? const SizedBox.shrink();
    final headerHeight = _headerSlotHeight(
      context,
      MediaQuery.sizeOf(context).width - 2 * _kScreenHPadding,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // The chart slot gives way first when a phone is short. It is derived
        // only from the viewport and the shared header height, so every screen
        // ends up with the exact same chart size and position on a device.
        final available = constraints.maxHeight;
        final fixedAroundChart = _kHeaderTopGap +
            headerHeight +
            _kHeaderToContent +
            _kContentToChart +
            _kChartToFooter +
            _kPrimaryButtonHeight +
            _kPrimaryToSecondary +
            _kSecondarySlotHeight +
            _kFooterBottomPadding;
        final forContentAndChart = available - fixedAroundChart;
        final chartHeight = (forContentAndChart - _kMinContentHeight)
            .clamp(_kMinChartSlotHeight, _kChartSlotHeight);

        return Column(
            children: [
              const SizedBox(height: _kHeaderTopGap),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: _kScreenHPadding),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: headerHeight),
                  child: header,
                ),
              ),
              const SizedBox(height: _kHeaderToContent),
              Expanded(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: _kScreenHPadding),
                  child: scrollContent
                      ? SingleChildScrollView(child: contentSlot)
                      : contentSlot,
                ),
              ),
              if (chart != null) ...[
                const SizedBox(height: _kContentToChart),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: _kScreenHPadding),
                  child: SizedBox(height: chartHeight, child: chart),
                ),
              ],
              const SizedBox(height: _kChartToFooter),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  _kScreenHPadding,
                  0,
                  _kScreenHPadding,
                  _kFooterBottomPadding,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: _kPrimaryButtonHeight,
                      width: double.infinity,
                      child: primaryAction,
                    ),
                    const SizedBox(height: _kPrimaryToSecondary),
                    SizedBox(
                      height: _kSecondarySlotHeight,
                      child: Center(child: secondaryAction),
                    ),
                  ],
                ),
              ),
            ],
        );
      },
    );
  }
}

/// Shared page header: accent icon, bold title, optional supporting text.
/// Icon size and spacing are identical on every screen.
class _ScreenHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  const _ScreenHeader({
    required this.icon,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF009682);
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: _kIconCircleSize,
            height: _kIconCircleSize,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: _kIconCircleSize * 0.48, color: accent),
          ),
        ),
        const SizedBox(height: _kIconToTitle),
        Text(
          title,
          textAlign: TextAlign.center,
          style: _headerTitleStyle(theme),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: _kTitleToDescription),
          Text(
            subtitle!,
            textAlign: TextAlign.center,
            style: _headerDescriptionStyle(theme),
          ),
        ],
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

/// One row of the vertical 7-point Likert scale.
class _LikertOption extends StatelessWidget {
  final int value;
  final String label;
  final VoidCallback onTap;

  const _LikertOption({
    required this.value,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: _panelColor(theme),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(
                Icons.circle_outlined,
                size: 22,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 14),
              Text(
                '$value',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
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
        color: _panelColor(theme),
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
        color: _panelColor(theme),
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
        color: _panelColor(theme),
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
        color: _panelColor(theme),
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
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      rows[i].$2,
                      textAlign: TextAlign.end,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
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
                    (
                      'Felt more relaxed',
                      _agreementText(r.relaxationAgreement)
                    ),
                    (
                      'Would use in private',
                      _agreementText(r.usageAgreement)
                    ),
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
  final double diameter;

  const _BreathingPulse({
    required this.controller,
    required this.reducedMotion,
    required this.startTime,
    required this.rampSeconds,
    required this.startHz,
    required this.endHz,
    this.diameter = 230,
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

        return SizedBox(
          width: diameter,
          height: diameter,
          child: Center(
            child: Container(
              width: diameter * 0.91 * scale,
              height: diameter * 0.91 * scale,
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
        );
      },
    );
  }
}

// ── Relaxation visual ─────────────────────────────────────────────────────────

class _RelaxationCircle extends StatelessWidget {
  final AnimationController controller;
  final bool reducedMotion;
  final double diameter;

  const _RelaxationCircle({
    required this.controller,
    required this.reducedMotion,
    this.diameter = 240,
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
          width: diameter,
          height: diameter,
          child: Center(
            child: Container(
              width: diameter * 0.79 * (1 + drift),
              height: diameter * 0.79 * (1 + drift),
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

// ── Shared styling helpers ────────────────────────────────────────────────────

/// Neutral grey panel background — the seed-tinted M3 surfaces look pink.
Color _panelColor(ThemeData theme) => theme.brightness == Brightness.dark
    ? const Color(0xFF2A2A2C)
    : const Color(0xFFF1F1F3);

Color _pwmColor(int pwm) {
  final t = (pwm / 255.0).clamp(0.0, 1.0);
  if (t <= 0.33) {
    return Color.lerp(
      const Color(0xFF2196F3), // blue
      const Color(0xFF4CAF50), // green
      t / 0.33,
    )!;
  }
  if (t <= 0.66) {
    return Color.lerp(
      const Color(0xFF4CAF50), // green
      const Color(0xFFFF9800), // orange
      (t - 0.33) / 0.33,
    )!;
  }
  return Color.lerp(
    const Color(0xFFFF9800), // orange
    const Color(0xFFF44336), // red
    (t - 0.66) / 0.34,
  )!;
}

String _warmthLabel(int pwm) {
  if (pwm == 0) return 'Off';
  if (pwm < 85) return 'Low';
  if (pwm < 170) return 'Medium';
  return 'High';
}

// Same gradient track as the manual control on the main Calmables page.
class _GradientSliderTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  const _GradientSliderTrackShape();

  static const _gradientColors = [
    Color(0xFF2196F3), // blue
    Color(0xFF4CAF50), // green
    Color(0xFFFF9800), // orange
    Color(0xFFF44336), // red
  ];

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    const trackHeight = 4.0;
    final thumbWidth = (sliderTheme.thumbShape ?? const RoundSliderThumbShape())
        .getPreferredSize(isEnabled, isDiscrete)
        .width;
    final trackLeft = offset.dx + thumbWidth / 2;
    final trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    final trackRight = trackLeft + parentBox.size.width - thumbWidth;
    return Rect.fromLTRB(
      trackLeft,
      trackTop,
      trackRight,
      trackTop + trackHeight,
    );
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    const radius = Radius.circular(4);
    final clampedThumb = thumbCenter.dx.clamp(trackRect.left, trackRect.right);

    // Full grey background track (always visible)
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, radius),
      Paint()..color = Colors.grey.shade300,
    );

    // Active (left) portion — gradient overlay
    if (clampedThumb > trackRect.left) {
      final activeRect = Rect.fromLTRB(
        trackRect.left,
        trackRect.top - additionalActiveTrackHeight / 2,
        clampedThumb,
        trackRect.bottom + additionalActiveTrackHeight / 2,
      );
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(activeRect, radius),
        Paint()
          ..shader = const LinearGradient(colors: _gradientColors)
              .createShader(trackRect),
      );
    }
  }
}
