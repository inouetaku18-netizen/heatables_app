import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:open_wearable/apps/calmables/model/ppg_filter.dart';
import 'package:open_wearable/apps/calmables/model/sensor_data_logger.dart';
import 'package:open_wearable/apps/calmables/widgets/rowling_chart.dart';
import 'package:open_wearable/apps/calmables/widgets/rolling_hr_chart.dart';

enum _Phase {
  participantIdInput,
  baselineReady,
  baselineRunning,
  questionnaire,
  mastPrepare,
  pendingTransition,
  hit1Running,
  ma1Running,
  hit2Running,
  ma2Running,
  hit3Running,
  ma3Running,
  relaxationReady,
  relaxationRunning,
  done,
}

class StudyProtocolPage extends StatefulWidget {
  final SensorDataLogger dataLogger;
  final Stream<PpgOpticalSample> ppgStream;
  final Stream<PpgMotionSample>? imuStream;
  final Stream<double?>? heartRateStream;
  final Stream<double?>? lfhfStream;

  // Optional display streams for the HR chart panel.
  final Stream<(int, double)>? displayPpgStream;
  final Stream<(int, double)>? rawHrStream;
  final Stream<(int, double)>? smoothedHrStream;
  final int timestampExponent;

  const StudyProtocolPage({
    super.key,
    required this.dataLogger,
    required this.ppgStream,
    this.imuStream,
    this.heartRateStream,
    this.lfhfStream,
    this.displayPpgStream,
    this.rawHrStream,
    this.smoothedHrStream,
    this.timestampExponent = -3,
  });

  @override
  State<StudyProtocolPage> createState() => _StudyProtocolPageState();
}

class _StudyProtocolPageState extends State<StudyProtocolPage> {
  _Phase _phase = _Phase.participantIdInput;
  final _participantIdController = TextEditingController();

  // Phase timer
  Timer? _phaseTimer;
  int _phaseRemainingSeconds = 0;

  // MA state
  int _maStartNumber = 0;   // fixed x for the current MA block
  int _maCurrentNumber = 0;
  int _maExpectedAnswer = 0;
  Timer? _maJudgementTimer;
  int _maJudgementCountdown = 0;
  int _maCorrectCount = 0;
  int _maWrongCount = 0;
  final _random = Random();

  // UI toggles
  bool _showCharts = false;

  // Transition screen state
  String _transitionTitle = '';
  String _transitionButtonLabel = '';
  IconData _transitionIcon = Icons.play_arrow_rounded;
  VoidCallback? _transitionCallback;
  VoidCallback? _transitionBackCallback;

  static const _kGreen = Color(0xFF009682);

  @override
  void dispose() {
    _phaseTimer?.cancel();
    _maJudgementTimer?.cancel();
    _participantIdController.dispose();
    super.dispose();
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  String _fmt(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  void _log(String label) => widget.dataLogger.logLabel(label);

  int _randomMaStart() => 2000 + _random.nextInt(501);

  void _startPhaseTimer(int seconds, VoidCallback onDone) {
    _phaseTimer?.cancel();
    _maJudgementTimer?.cancel();
    setState(() => _phaseRemainingSeconds = seconds);
    _phaseTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _phaseRemainingSeconds--;
        if (_phaseRemainingSeconds <= 0) {
          t.cancel();
          onDone();
        }
      });
    });
  }

  void _startJudgementCountdown() {
    _maJudgementTimer?.cancel();
    setState(() => _maJudgementCountdown = 5);
    _maJudgementTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _maJudgementCountdown--;
        if (_maJudgementCountdown <= 0) {
          t.cancel();
          _onMaTimeout();
        }
      });
    });
  }

  // ── Phase transitions ─────────────────────────────────────────────────────────

  Future<void> _startRecording(String participantId) async {
    await widget.dataLogger.start(
      ppgStream: widget.ppgStream,
      imuStream: widget.imuStream,
      heartRateStream: widget.heartRateStream,
      lfhfStream: widget.lfhfStream,
      participantId: participantId,
    );
    if (!mounted) return;
    setState(() => _phase = _Phase.baselineReady);
  }

  void _startBaseline() {
    _log('baseline_start');
    setState(() => _phase = _Phase.baselineRunning);
    _startPhaseTimer(5 * 60, () {
      _log('baseline_end');
      if (mounted) setState(() => _phase = _Phase.questionnaire);
    });
  }

  void _restartBaseline() {
    _phaseTimer?.cancel();
    _log('baseline_restart');
    _startBaseline();
  }

  void _startMast() {
    _log('mast_start');
    _beginHit(1, 90, _readyMa1);
  }

  void _beginHit(int number, int durationSeconds, VoidCallback onDone) {
    _log('hit_${number}_start');
    final phase = switch (number) {
      1 => _Phase.hit1Running,
      2 => _Phase.hit2Running,
      _ => _Phase.hit3Running,
    };
    setState(() => _phase = phase);
    _startPhaseTimer(durationSeconds, () {
      _log('hit_${number}_end');
      onDone();
    });
  }

  void _beginMa(int number, int durationSeconds, VoidCallback onDone) {
    _log('ma_${number}_start');
    _maCorrectCount = 0;
    _maWrongCount = 0;
    _maStartNumber = _randomMaStart();
    _maCurrentNumber = _maStartNumber;
    _maExpectedAnswer = _maCurrentNumber - 17;
    _log('ma_${number}_start_x_$_maStartNumber');
    final phase = switch (number) {
      1 => _Phase.ma1Running,
      2 => _Phase.ma2Running,
      _ => _Phase.ma3Running,
    };
    setState(() {
      _phase = phase;
    });
    _startJudgementCountdown();
    _startPhaseTimer(durationSeconds, () {
      _maJudgementTimer?.cancel();
      _log('ma_${number}_end');
      onDone();
    });
  }

  void _awaitTransition(String title, String buttonLabel, IconData icon, VoidCallback callback, {VoidCallback? backCallback}) {
    setState(() {
      _phase = _Phase.pendingTransition;
      _transitionTitle = title;
      _transitionButtonLabel = buttonLabel;
      _transitionIcon = icon;
      _transitionCallback = callback;
      _transitionBackCallback = backCallback;
    });
  }

  void _readyMa1() => _awaitTransition('Kopfrechnen 1', 'Kopfrechnen starten', Icons.calculate_rounded, _startMa1,
      backCallback: () { _phaseTimer?.cancel(); _maJudgementTimer?.cancel(); _beginHit(1, 90, _readyMa1); });
  void _startMa1() => _beginMa(1, 45, _readyHit2);
  void _readyHit2() => _awaitTransition('Hand Immersion 2', 'Hand Immersion starten', Icons.water_rounded, _doHit2,
      backCallback: () { _phaseTimer?.cancel(); _maJudgementTimer?.cancel(); _beginMa(1, 45, _readyHit2); });
  void _doHit2() => _beginHit(2, 60, _readyMa2);
  void _readyMa2() => _awaitTransition('Kopfrechnen 2', 'Kopfrechnen starten', Icons.calculate_rounded, _startMa2,
      backCallback: () { _phaseTimer?.cancel(); _maJudgementTimer?.cancel(); _beginHit(2, 60, _readyMa2); });
  void _startMa2() => _beginMa(2, 60, _readyHit3);
  void _readyHit3() => _awaitTransition('Hand Immersion 3', 'Hand Immersion starten', Icons.water_rounded, _doHit3,
      backCallback: () { _phaseTimer?.cancel(); _maJudgementTimer?.cancel(); _beginMa(2, 60, _readyHit3); });
  void _doHit3() => _beginHit(3, 60, _readyMa3);
  void _readyMa3() => _awaitTransition('Kopfrechnen 3', 'Kopfrechnen starten', Icons.calculate_rounded, _startMa3,
      backCallback: () { _phaseTimer?.cancel(); _maJudgementTimer?.cancel(); _beginHit(3, 60, _readyMa3); });
  void _startMa3() => _beginMa(3, 90, () {
        _log('mast_end');
        if (mounted) setState(() => _phase = _Phase.relaxationReady);
      });

  void _onMaCorrect() {
    _maJudgementTimer?.cancel();
    _maCorrectCount++;
    _maCurrentNumber = _maExpectedAnswer;
    _log('ma_correct_${_maExpectedAnswer}');
    _maExpectedAnswer = _maCurrentNumber - 17;
    setState(() {});
    _startJudgementCountdown();
  }

  void _onMaWrong() {
    _maJudgementTimer?.cancel();
    _maWrongCount++;
    _maCurrentNumber = _maStartNumber;
    _maExpectedAnswer = _maCurrentNumber - 17;
    _log('ma_wrong_restart_from_x_$_maStartNumber');
    setState(() {});
    _startJudgementCountdown();
  }

  void _onMaTimeout() {
    _maWrongCount++;
    _maCurrentNumber = _maStartNumber;
    _maExpectedAnswer = _maCurrentNumber - 17;
    _log('ma_timeout_restart_from_x_$_maStartNumber');
    setState(() {});
    _startJudgementCountdown();
  }

  void _startRelaxation() {
    _log('relaxation_start');
    setState(() => _phase = _Phase.relaxationRunning);
    _startPhaseTimer(15 * 60, () {
      _log('relaxation_end');
      if (mounted) setState(() => _phase = _Phase.done);
    });
  }

  void _restartProtocol() {
    _phaseTimer?.cancel();
    _maJudgementTimer?.cancel();
    _log('protocol_restart');
    setState(() {
      _phase = _Phase.baselineReady;
      _phaseRemainingSeconds = 0;
    });
  }

  void _skipPhase() {
    _phaseTimer?.cancel();
    _maJudgementTimer?.cancel();
    _log('skip_${_phase.name}');
    switch (_phase) {
      // Baseline: skip entire baseline section → MAST preparation
      case _Phase.baselineRunning:
        _log('baseline_end');
        setState(() => _phase = _Phase.mastPrepare);
      case _Phase.questionnaire:
        setState(() => _phase = _Phase.mastPrepare);
      // MAST: skip entire remaining MAST → relaxation
      case _Phase.mastPrepare:
      case _Phase.pendingTransition:
      case _Phase.hit1Running:
      case _Phase.ma1Running:
      case _Phase.hit2Running:
      case _Phase.ma2Running:
      case _Phase.hit3Running:
      case _Phase.ma3Running:
        _log('mast_end');
        setState(() => _phase = _Phase.relaxationReady);
      case _Phase.relaxationReady:
        _startRelaxation();
      case _Phase.relaxationRunning:
        _log('relaxation_end');
        setState(() => _phase = _Phase.done);
      default:
        break;
    }
  }

  void _goBack() {
    _phaseTimer?.cancel();
    _maJudgementTimer?.cancel();
    _log('back_${_phase.name}');
    switch (_phase) {
      case _Phase.baselineRunning:
        setState(() { _phase = _Phase.baselineReady; _phaseRemainingSeconds = 0; });
      case _Phase.questionnaire:
        setState(() { _phase = _Phase.baselineReady; _phaseRemainingSeconds = 0; });
      case _Phase.mastPrepare:
        setState(() => _phase = _Phase.questionnaire);
      case _Phase.pendingTransition:
        _transitionBackCallback?.call();
      case _Phase.hit1Running:
        setState(() => _phase = _Phase.mastPrepare);
      case _Phase.ma1Running:
        _beginHit(1, 90, _readyMa1);
      case _Phase.hit2Running:
        _beginMa(1, 45, _readyHit2);
      case _Phase.ma2Running:
        _beginHit(2, 60, _readyMa2);
      case _Phase.hit3Running:
        _beginMa(2, 60, _readyHit3);
      case _Phase.ma3Running:
        _beginHit(3, 60, _readyMa3);
      case _Phase.relaxationReady:
        setState(() => _phase = _Phase.mastPrepare);
      case _Phase.relaxationRunning:
        setState(() { _phase = _Phase.relaxationReady; _phaseRemainingSeconds = 0; });
      default:
        break;
    }
  }

  bool get _phaseIsSkippable =>
      _phase != _Phase.participantIdInput &&
      _phase != _Phase.baselineReady &&
      _phase != _Phase.done;

  bool get _canGoBack =>
      _phase != _Phase.participantIdInput &&
      _phase != _Phase.baselineReady &&
      _phase != _Phase.done;

  String get _skipLabel {
    if (_phase == _Phase.baselineRunning || _phase == _Phase.questionnaire) {
      return 'Baseline überspringen';
    }
    if (_phase == _Phase.mastPrepare ||
        _phase == _Phase.pendingTransition ||
        _phase == _Phase.hit1Running ||
        _phase == _Phase.ma1Running ||
        _phase == _Phase.hit2Running ||
        _phase == _Phase.ma2Running ||
        _phase == _Phase.hit3Running ||
        _phase == _Phase.ma3Running) {
      return 'MAST überspringen';
    }
    return 'Schritt überspringen';
  }

  bool get _chartsAvailable =>
      widget.displayPpgStream != null ||
      (widget.rawHrStream != null && widget.smoothedHrStream != null);

  Future<void> _stopAndShare() async {
    _phaseTimer?.cancel();
    _maJudgementTimer?.cancel();
    await widget.dataLogger.stopAndShare();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _onBackPressed() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Protokoll verlassen?'),
        content: const Text(
          'Die Aufnahme läuft weiter, aber die Protokollschritte werden nicht mehr getrackt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Bleiben'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Verlassen'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      _phaseTimer?.cancel();
      _maJudgementTimer?.cancel();
      Navigator.of(context).pop();
    }
  }

  Future<void> _confirmRestartProtocol() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Protokoll neu starten?'),
        content: const Text(
          'Geht zurück zur Baseline. Die Aufnahme läuft weiter.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Neu starten'),
          ),
        ],
      ),
    );
    if (ok == true) _restartProtocol();
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final showRestartOption =
        _phase != _Phase.participantIdInput && _phase != _Phase.done;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBackPressed();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Study Protocol'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _onBackPressed,
          ),
          actions: [
            IconButton(
              icon: Icon(
                _showCharts
                    ? Icons.monitor_heart
                    : Icons.monitor_heart_outlined,
                color: Colors.white,
              ),
              tooltip: 'Herzrate anzeigen',
              onPressed: _chartsAvailable
                  ? () => setState(() => _showCharts = !_showCharts)
                  : null,
            ),
            if (showRestartOption)
              TextButton.icon(
                onPressed: _confirmRestartProtocol,
                icon: const Icon(Icons.refresh, color: Colors.white),
                label: const Text(
                  'Restart',
                  style: TextStyle(color: Colors.white),
                ),
              ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (_showCharts && _chartsAvailable) _buildChartsPanel(),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      _buildBody(),
                      if (_phaseIsSkippable || _canGoBack) ...[                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (_canGoBack)
                              TextButton.icon(
                                onPressed: _goBack,
                                icon: const Icon(
                                  Icons.arrow_back_rounded,
                                  color: Colors.grey,
                                ),
                                label: const Text(
                                  'Zurück',
                                  style: TextStyle(color: Colors.grey),
                                ),
                              ),
                            if (_canGoBack && _phaseIsSkippable)
                              const SizedBox(width: 16),
                            if (_phaseIsSkippable)
                              TextButton.icon(
                                onPressed: _skipPhase,
                                icon: const Icon(
                                  Icons.skip_next_rounded,
                                  color: Colors.grey,
                                ),
                                label: Text(
                                  _skipLabel,
                                  style: const TextStyle(color: Colors.grey),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChartsPanel() {
    return Container(
      color: Colors.black,
      child: Column(
        children: [
          if (widget.displayPpgStream != null) ...[
            const Padding(
              padding: EdgeInsets.only(top: 4, left: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'PPG',
                  style: TextStyle(color: Colors.white60, fontSize: 10),
                ),
              ),
            ),
            SizedBox(
              height: 80,
              child: RollingChart(
                dataSteam: widget.displayPpgStream!,
                timestampExponent: widget.timestampExponent,
                timeWindow: 10,
                showXAxis: false,
              ),
            ),
          ],
          if (widget.rawHrStream != null && widget.smoothedHrStream != null) ...[
            const Padding(
              padding: EdgeInsets.only(top: 2, left: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'HR (bpm)',
                  style: TextStyle(color: Colors.white60, fontSize: 10),
                ),
              ),
            ),
            SizedBox(
              height: 80,
              child: RollingHrChart(
                rawHrStream: widget.rawHrStream!,
                smoothedHrStream: widget.smoothedHrStream!,
                timestampExponent: widget.timestampExponent,
                timeWindow: 60,
              ),
            ),
          ],
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return switch (_phase) {
      _Phase.participantIdInput => _buildParticipantIdInput(),
      _Phase.baselineReady => _buildBaselineReady(),
      _Phase.baselineRunning => _buildBaselineRunning(),
      _Phase.questionnaire => _buildQuestionnaire(),
      _Phase.mastPrepare => _buildMastPrepare(),
      _Phase.pendingTransition => _buildTransitionReady(),
      _Phase.hit1Running => _buildHitPhase(1, 90),
      _Phase.ma1Running => _buildMaPhase(1, 45),
      _Phase.hit2Running => _buildHitPhase(2, 60),
      _Phase.ma2Running => _buildMaPhase(2, 60),
      _Phase.hit3Running => _buildHitPhase(3, 60),
      _Phase.ma3Running => _buildMaPhase(3, 90),
      _Phase.relaxationReady => _buildRelaxationReady(),
      _Phase.relaxationRunning => _buildRelaxationRunning(),
      _Phase.done => _buildDone(),
    };
  }

  // ── Phase widgets ─────────────────────────────────────────────────────────────

  Widget _buildParticipantIdInput() {
    return Column(
      children: [
        const SizedBox(height: 48),
        const Icon(Icons.person_rounded, size: 72, color: _kGreen),
        const SizedBox(height: 24),
        _phaseTitle('Participant ID'),
        const SizedBox(height: 8),
        const Text(
          'Alle Aufnahme-Dateien werden mit dieser ID benannt.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _participantIdController,
          decoration: const InputDecoration(
            labelText: 'Participant ID',
            hintText: 'z. B. P001',
            border: OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.done,
          autofocus: true,
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () async {
              final id = _participantIdController.text.trim();
              if (id.isEmpty) return;
              await _startRecording(id);
            },
            icon: const Icon(Icons.fiber_manual_record),
            label: const Text('Aufnahme starten & Protokoll beginnen'),
            style: _primaryStyle(),
          ),
        ),
      ],
    );
  }

  Widget _buildTransitionReady() => _buildReadyScreen(
        icon: _transitionIcon,
        title: _transitionTitle,
        description: 'Bereit für den nächsten Schritt?',
        buttonLabel: _transitionButtonLabel,
        onStart: _transitionCallback ?? () {},
      );

  Widget _buildBaselineReady() => _buildReadyScreen(
        icon: Icons.self_improvement_rounded,
        title: 'Baseline',
        description:
            'Bitte stellen Sie sicher, dass die Versuchsperson ruhig sitzt und entspannt ist.',
        buttonLabel: 'Baseline starten',
        onStart: _startBaseline,
      );

  Widget _buildBaselineRunning() {
    return Column(
      children: [
        const SizedBox(height: 48),
        _phaseTitle('Baseline'),
        const SizedBox(height: 40),
        _timerDisplay(_phaseRemainingSeconds),
        const SizedBox(height: 40),
        OutlinedButton.icon(
          onPressed: _restartBaseline,
          icon: const Icon(Icons.refresh),
          label: const Text('Baseline neu starten'),
        ),
      ],
    );
  }

  Widget _buildQuestionnaire() {
    return Column(
      children: [
        const SizedBox(height: 48),
        const Icon(Icons.assignment_rounded, size: 72, color: _kGreen),
        const SizedBox(height: 24),
        _phaseTitle('UX Fragebogen'),
        const SizedBox(height: 16),
        const Text(
          'Bitte die Versuchsperson auffordern,\nden UX-Fragebogen jetzt auszufüllen.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 40),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => setState(() => _phase = _Phase.mastPrepare),
            style: _primaryStyle(),
            child: const Text('Weiter zum MAST'),
          ),
        ),
      ],
    );
  }

  Widget _buildMastPrepare() {
    return Column(
      children: [
        const SizedBox(height: 48),
        const Icon(Icons.water_rounded, size: 72, color: _kGreen),
        const SizedBox(height: 24),
        _phaseTitle('Vorbereitung Hand Immersion'),
        const SizedBox(height: 16),
        const Text(
          'Kaltwasserbehälter für Hand Immersion vorbereiten.\nWenn die Versuchsperson bereit ist, Start drücken.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 40),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _startMast,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('MAST starten'),
            style: _primaryStyle(),
          ),
        ),
      ],
    );
  }

  Widget _buildHitPhase(int number, int totalSeconds) {
    return Column(
      children: [
        const SizedBox(height: 48),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.water_rounded, size: 28, color: _kGreen),
            const SizedBox(width: 8),
            _phaseTitle('HIT $number – Hand Immersion Task'),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Dauer: ${totalSeconds}s',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 40),
        _timerDisplay(_phaseRemainingSeconds),
      ],
    );
  }

  Widget _buildMaPhase(int number, int totalSeconds) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.calculate_rounded, size: 28, color: _kGreen),
            const SizedBox(width: 8),
            _phaseTitle('MA $number – Mental Arithmetic'),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Startzahl: $_maStartNumber  ·  Gesamt: ${totalSeconds}s',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        _timerDisplay(_phaseRemainingSeconds),
        const SizedBox(height: 12),
        Text(
          '$_maCorrectCount ✓   $_maWrongCount ✗',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const Divider(height: 32),
        Text(
          '$_maCurrentNumber − 17 = ?',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: Colors.grey),
          ),
          const SizedBox(height: 4),
          const Text(
            'Erwartete Antwort',
            style: TextStyle(color: Colors.grey, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Text(
            '$_maExpectedAnswer',
            style: Theme.of(context).textTheme.displayLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: Colors.orange.shade700,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 56,
            height: 56,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: _maJudgementCountdown / 5,
                  strokeWidth: 5,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation(
                    _maJudgementCountdown <= 2
                        ? Colors.red
                        : Colors.orange.shade600,
                  ),
                ),
                Text(
                  '$_maJudgementCountdown',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _onMaCorrect,
                  icon: const Icon(Icons.check_rounded, size: 24),
                  label: const Text('Richtig', style: TextStyle(fontSize: 16)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade600,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _onMaWrong,
                  icon: const Icon(Icons.close_rounded, size: 24),
                  label: const Text('Falsch', style: TextStyle(fontSize: 16)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade600,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildRelaxationReady() => _buildReadyScreen(
        icon: Icons.spa_rounded,
        title: 'Relaxationsphase',
        description:
            'MAST abgeschlossen.\nBitte Versuchsperson zur Entspannung auffordern.\nDenken Sie daran, Calmables zu starten.',
        buttonLabel: 'Relaxation starten (15 min)',
        onStart: _startRelaxation,
      );

  Widget _buildRelaxationRunning() {
    return Column(
      children: [
        const SizedBox(height: 48),
        _phaseTitle('Relaxation'),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: _kGreen.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tips_and_updates_rounded, color: _kGreen, size: 20),
              SizedBox(width: 8),
              Text(
                'Calmables jetzt starten',
                style: TextStyle(
                  color: _kGreen,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),
        _timerDisplay(_phaseRemainingSeconds),
      ],
    );
  }

  Widget _buildDone() {
    return Column(
      children: [
        const SizedBox(height: 48),
        const Icon(Icons.check_circle_rounded, size: 80, color: _kGreen),
        const SizedBox(height: 24),
        _phaseTitle('Protokoll abgeschlossen'),
        const SizedBox(height: 16),
        const Text(
          'Alle Phasen beendet.\nAufnahme stoppen und Daten teilen.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 40),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _stopAndShare,
            icon: const Icon(Icons.share_rounded),
            label: const Text('Aufnahme stoppen & teilen'),
            style: _primaryStyle(),
          ),
        ),
      ],
    );
  }

  // ── Shared helpers ────────────────────────────────────────────────────────────

  Widget _buildReadyScreen({
    required IconData icon,
    required String title,
    required String description,
    required String buttonLabel,
    required VoidCallback onStart,
  }) {
    return Column(
      children: [
        const SizedBox(height: 48),
        Icon(icon, size: 72, color: _kGreen),
        const SizedBox(height: 24),
        _phaseTitle(title),
        const SizedBox(height: 16),
        Text(
          description,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 40),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: onStart,
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(buttonLabel),
            style: _primaryStyle(),
          ),
        ),
      ],
    );
  }

  Widget _phaseTitle(String title) => Text(
        title,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.bold,
        ),
      );

  Widget _timerDisplay(int seconds) => Text(
        _fmt(seconds),
        style: Theme.of(context).textTheme.displayLarge?.copyWith(
          fontWeight: FontWeight.w300,
          letterSpacing: 4,
        ),
      );

  ButtonStyle _primaryStyle() => ElevatedButton.styleFrom(
        backgroundColor: _kGreen,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 16),
      );
}
