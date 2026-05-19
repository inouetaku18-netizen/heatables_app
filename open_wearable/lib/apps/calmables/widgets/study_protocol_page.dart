import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:open_wearable/apps/calmables/model/ppg_filter.dart';
import 'package:open_wearable/apps/calmables/model/sensor_data_logger.dart';
import 'package:open_wearable/apps/calmables/widgets/calmables_card_styles.dart';
import 'package:open_wearable/apps/calmables/widgets/rowling_chart.dart';
import 'package:open_wearable/apps/calmables/widgets/rolling_hr_chart.dart';

enum _Phase {
  participantIdInput,
  syncDevices,
  calmablesPowerAdjust,
  demographicsInput,
  akklimatisation,
  akklimatisationRunning,
  baselineReady,
  baselineRunning,
  surveyHintPreMast,
  mastPrepare,
  pendingTransition,
  hit1Running,
  ma1Running,
  hit2Running,
  ma2Running,
  hit3Running,
  ma3Running,
  hit4Running,
  ma4Running,
  hit5Running,
  surveyHintPostMast,
  relaxationReady,
  relaxationRunning,
  surveyHintFinal,
  questionnaire,
  done,
}

enum _BlockOrder { treatmentFirst, controlFirst }

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
  final Stream<PpgSignalQuality>? signalQualityStream;
  final int timestampExponent;

  // Calmables control
  final Future<void> Function(List<int>)? onSendToCalmables;
  final Future<bool> Function()? onConnectCalmables;

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
    this.signalQualityStream,
    this.timestampExponent = -3,
    this.onSendToCalmables,
    this.onConnectCalmables,
  });

  @override
  State<StudyProtocolPage> createState() => _StudyProtocolPageState();
}

class _StudyProtocolPageState extends State<StudyProtocolPage>
    with TickerProviderStateMixin {
  _Phase _phase = _Phase.participantIdInput;
  final _participantIdController = TextEditingController();

  // Phase timer
  Timer? _phaseTimer;
  int _phaseRemainingSeconds = 0;

  // MA state
  int _maStartNumber = 0; // fixed x for the current MA block
  int _maCurrentNumber = 0;
  int _maExpectedAnswer = 0;
  Timer? _maJudgementTimer;
  AnimationController? _judgementAnim; // drives smooth ring 1.0→0.0 over 5s
  int _maCorrectCount = 0;
  int _maWrongCount = 0;
  int _totalMaWrongCount = 0; // accumulates across all MA blocks for dashboard
  final _random = Random();

  // Transition state
  bool _transitionIsMa = false;

  // UI toggles: 0=hidden, 1=cards only, 2=cards+charts
  int _showCharts = 0;

  // Calmables state
  int _calmablesPowerValue = 0; // saved from power-adjust step
  int _relaxationCurrentPwm = 0; // live value during relaxation
  bool _calmablesOn = false;

  // Transition screen state (non-MA fields)
  String _transitionTitle = '';
  String _transitionButtonLabel = '';
  IconData _transitionIcon = Icons.play_arrow_rounded;
  VoidCallback? _transitionCallback;
  VoidCallback? _transitionBackCallback;
  VoidCallback?
      _transitionSkipCallback; // for MA transitions: jumps past the MA

  // Block protocol order (set at ID input)
  _BlockOrder _blockOrder = _BlockOrder.treatmentFirst;
  int _currentBlockNumber = 1; // 1 or 2

  // Dashboard WebSocket server
  HttpServer? _wsServer;
  final List<WebSocket> _wsClients = [];
  String? _wsAddress; // e.g. "192.168.1.42:8080"

  static const _kGreen = Color(0xFF009682);

  @override
  void initState() {
    super.initState();
    _startDashboardServer();
  }

  @override
  void dispose() {
    _wsServer?.close(force: true);
    for (final ws in _wsClients) {
      ws.close();
    }
    _phaseTimer?.cancel();
    _maJudgementTimer?.cancel();
    _judgementAnim?.dispose();
    _participantIdController.dispose();
    super.dispose();
  }

  // ── Dashboard WebSocket server ────────────────────────────────────────────────

  Future<void> _startDashboardServer() async {
    try {
      _wsServer =
          await HttpServer.bind(InternetAddress.anyIPv4, 8080, shared: true);
      // Find local non-loopback IPv4 address
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            if (mounted) setState(() => _wsAddress = '${addr.address}:8080');
            break;
          }
        }
        if (_wsAddress != null) break;
      }
      _wsServer!.listen((HttpRequest req) async {
        if (WebSocketTransformer.isUpgradeRequest(req)) {
          req.response.headers.add('Access-Control-Allow-Origin', '*');
          final ws = await WebSocketTransformer.upgrade(req);
          _wsClients.add(ws);
          _sendDashboardState(ws);
          ws.listen(
            (dynamic event) => _handleDashboardMessage(ws, event),
            onDone: () => _wsClients.remove(ws),
            onError: (_) => _wsClients.remove(ws),
          );
        } else {
          req.response
            ..statusCode = 200
            ..headers.add('Access-Control-Allow-Origin', '*')
            ..close();
        }
      });
    } catch (_) {
      // Server couldn't start (e.g. port in use)
    }
  }

  int get _dashboardAmountCents {
    // Block 1: minimum 30€ (3000 ct), Block 2: minimum 20€ (2000 ct)
    final minCents = _currentBlockNumber == 1 ? 3000 : 2000;
    return (4000 - _totalMaWrongCount * 20).clamp(minCents, 4000);
  }

  int get _dashboardDeductionCents => 4000 - _dashboardAmountCents;

  int get _dashboardErrorCount => _dashboardDeductionCents ~/ 20;

  bool get _dashboardTimerRunning =>
      _phase == _Phase.ma1Running ||
      _phase == _Phase.ma2Running ||
      _phase == _Phase.ma3Running ||
      _phase == _Phase.ma4Running;

  void _sendDashboardState(WebSocket ws) {
    try {
      ws.add(
        jsonEncode(<String, dynamic>{
          'type': 'state',
          'amountCents': _dashboardAmountCents,
          'errorCount': _dashboardErrorCount,
          'deductionCents': _dashboardDeductionCents,
          'isRunning': _dashboardTimerRunning,
        }),
      );
    } catch (_) {
      _wsClients.remove(ws);
    }
  }

  void _broadcastWs(Map<String, dynamic> data) {
    if (_wsClients.isEmpty) return;
    final msg = jsonEncode(data);
    for (final ws in List.of(_wsClients)) {
      try {
        ws.add(msg);
      } catch (_) {
        _wsClients.remove(ws);
      }
    }
  }

  void _broadcastDashboardState() {
    _broadcastWs(<String, dynamic>{
      'type': 'state',
      'amountCents': _dashboardAmountCents,
      'errorCount': _dashboardErrorCount,
      'deductionCents': _dashboardDeductionCents,
      'isRunning': _dashboardTimerRunning,
    });
  }

  void _handleDashboardMessage(WebSocket ws, dynamic event) {
    if (event is! String) return;

    try {
      final decoded = jsonDecode(event);
      if (decoded is! Map<String, dynamic>) return;
      final type = decoded['type'];
      if (type is! String) return;

      switch (type) {
        case 'state_request':
          _sendDashboardState(ws);
          break;
        case 'error':
          if (_dashboardTimerRunning) {
            _onMaWrong();
          } else {
            final minCents = _currentBlockNumber == 1 ? 3000 : 2000;
            if (_dashboardAmountCents > minCents) {
              setState(() {
                _maWrongCount++;
              });
            }
            _broadcastDashboardState();
          }
          break;
        case 'undo':
          if (_maWrongCount > 0) {
            setState(() {
              _maWrongCount--;
            });
          }
          _broadcastDashboardState();
          break;
        case 'reset':
          setState(() {
            _maWrongCount = 0;
            _totalMaWrongCount = 0;
          });
          _broadcastDashboardState();
          break;
        case 'correct':
          if (_dashboardTimerRunning) {
            _onMaCorrect();
          } else {
            _broadcastDashboardState();
          }
          break;
        default:
          break;
      }
    } catch (_) {
      // Ignore malformed dashboard commands to keep the protocol running.
    }
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
    _judgementAnim?.dispose();
    _judgementAnim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
      value: 1.0,
    )
      ..addStatusListener((status) {
        if (status == AnimationStatus.dismissed && mounted) {
          _onMaTimeout();
        }
      })
      ..reverse();
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
    setState(() => _phase = _Phase.syncDevices);
  }

  void _startAkklimatisation() {
    _log('akklimatisation_start');
    setState(() => _phase = _Phase.akklimatisationRunning);
    _startPhaseTimer(15 * 60, () {
      _log('akklimatisation_end');
      if (mounted) setState(() => _phase = _Phase.baselineReady);
    });
  }

  void _startBaseline() {
    _log('baseline_start');
    setState(() => _phase = _Phase.baselineRunning);
    _startPhaseTimer(5 * 60, () {
      _log('baseline_end');
      if (mounted) setState(() => _phase = _Phase.surveyHintPreMast);
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
      3 => _Phase.hit3Running,
      4 => _Phase.hit4Running,
      _ => _Phase.hit5Running,
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
    // _totalMaWrongCount is NOT reset here – it accumulates across all MA blocks
    // _maStartNumber is already set by _readyMa*
    _maCurrentNumber = _maStartNumber;
    _maExpectedAnswer = _maStartNumber; // first: VP says the start number
    _log('ma_${number}_start_x_$_maStartNumber');
    final phase = switch (number) {
      1 => _Phase.ma1Running,
      2 => _Phase.ma2Running,
      3 => _Phase.ma3Running,
      _ => _Phase.ma4Running,
    };
    setState(() {
      _phase = phase;
    });
    _broadcastWs({'type': 'ma_start', 'number': number});
    _broadcastDashboardState();
    _startJudgementCountdown();
    _startPhaseTimer(durationSeconds, () {
      _maJudgementTimer?.cancel();
      _judgementAnim?.stop();
      _log('ma_${number}_end');
      _broadcastWs({'type': 'ma_stop'});
      _broadcastDashboardState();
      onDone();
    });
  }

  void _awaitTransition(
      String title, String buttonLabel, IconData icon, VoidCallback callback,
      {VoidCallback? backCallback, VoidCallback? skipCallback}) {
    setState(() {
      _phase = _Phase.pendingTransition;
      _transitionTitle = title;
      _transitionButtonLabel = buttonLabel;
      _transitionIcon = icon;
      _transitionCallback = callback;
      _transitionBackCallback = backCallback;
      _transitionSkipCallback = skipCallback;
    });
  }

  void _readyMa1() {
    _maStartNumber = _randomMaStart();
    _transitionIsMa = true;
    _awaitTransition('Kopfrechnen 1', 'Kopfrechnen starten',
        Icons.calculate_rounded, _startMa1, backCallback: () {
      _phaseTimer?.cancel();
      _maJudgementTimer?.cancel();
      _judgementAnim?.stop();
      setState(() => _phase = _Phase.mastPrepare);
    }, skipCallback: _readyHit2);
  }

  void _startMa1() => _beginMa(1, 45, _readyHit2);
  void _readyHit2() {
    _transitionIsMa = false;
    _awaitTransition('Hand Immersion 2', 'Hand Immersion starten',
        Icons.water_rounded, _doHit2, backCallback: () {
      _readyMa1();
    }, skipCallback: _readyMa2);
  }

  void _doHit2() => _beginHit(2, 60, _readyMa2);
  void _readyMa2() {
    _maStartNumber = _randomMaStart();
    _transitionIsMa = true;
    _awaitTransition('Kopfrechnen 2', 'Kopfrechnen starten',
        Icons.calculate_rounded, _startMa2, backCallback: () {
      _phaseTimer?.cancel();
      _maJudgementTimer?.cancel();
      _judgementAnim?.stop();
      _readyHit2();
    }, skipCallback: _readyHit3);
  }

  void _startMa2() => _beginMa(2, 60, _readyHit3);
  void _readyHit3() {
    _transitionIsMa = false;
    _awaitTransition('Hand Immersion 3', 'Hand Immersion starten',
        Icons.water_rounded, _doHit3, backCallback: () {
      _readyMa2();
    }, skipCallback: _readyMa3);
  }

  void _doHit3() => _beginHit(3, 60, _readyMa3);
  void _readyMa3() {
    _maStartNumber = _randomMaStart();
    _transitionIsMa = true;
    _awaitTransition('Kopfrechnen 3', 'Kopfrechnen starten',
        Icons.calculate_rounded, _startMa3, backCallback: () {
      _phaseTimer?.cancel();
      _maJudgementTimer?.cancel();
      _judgementAnim?.stop();
      _readyHit3();
    }, skipCallback: _readyHit4);
  }

  void _startMa3() => _beginMa(3, 90, _readyHit4);

  void _readyHit4() {
    _transitionIsMa = false;
    _awaitTransition('Hand Immersion 4', 'Hand Immersion starten',
        Icons.water_rounded, _doHit4, backCallback: () {
      _readyMa3();
    }, skipCallback: _readyMa4);
  }

  void _doHit4() => _beginHit(4, 90, _readyMa4);
  void _readyMa4() {
    _maStartNumber = _randomMaStart();
    _transitionIsMa = true;
    _awaitTransition('Kopfrechnen 4', 'Kopfrechnen starten',
        Icons.calculate_rounded, _startMa4, backCallback: () {
      _phaseTimer?.cancel();
      _maJudgementTimer?.cancel();
      _judgementAnim?.stop();
      _readyHit4();
    }, skipCallback: _readyHit5);
  }

  void _startMa4() => _beginMa(4, 45, _readyHit5);

  void _readyHit5() {
    _transitionIsMa = false;
    _awaitTransition('Hand Immersion 5', 'Hand Immersion starten',
        Icons.water_rounded, _doHit5, backCallback: () {
      _readyMa4();
    }, skipCallback: () {
      _log('hit_5_skip');
      _log('mast_end');
      setState(() => _phase = _Phase.surveyHintPostMast);
    });
  }

  void _doHit5() => _beginHit(5, 60, () {
        _log('mast_end');
        if (mounted) setState(() => _phase = _Phase.surveyHintPostMast);
      });

  void _onMaCorrect() {
    _maJudgementTimer?.cancel();
    _judgementAnim?.stop();
    _maCorrectCount++;
    _maCurrentNumber = _maExpectedAnswer;
    _log('ma_correct_${_maExpectedAnswer}');
    _maExpectedAnswer = _maCurrentNumber - 17;
    _broadcastWs({'type': 'correct'});
    _broadcastDashboardState();
    setState(() {});
    _startJudgementCountdown();
  }

  void _onMaWrong() {
    _maJudgementTimer?.cancel();
    _judgementAnim?.stop();
    _maWrongCount++;
    _totalMaWrongCount++;
    _maCurrentNumber = _maStartNumber;
    _maExpectedAnswer = _maStartNumber; // restart: VP says start number again
    _log('ma_wrong_restart_from_x_$_maStartNumber');
    _broadcastWs({'type': 'error'});
    _broadcastDashboardState();
    setState(() {});
    _startJudgementCountdown();
  }

  void _onMaTimeout() {
    if (_phase != _Phase.ma1Running &&
        _phase != _Phase.ma2Running &&
        _phase != _Phase.ma3Running &&
        _phase != _Phase.ma4Running) return;
    _maWrongCount++;
    _totalMaWrongCount++;
    _maCurrentNumber = _maStartNumber;
    _maExpectedAnswer = _maStartNumber; // restart: VP says start number again
    _log('ma_timeout_restart_from_x_$_maStartNumber');
    _broadcastWs({'type': 'timeout'});
    _broadcastDashboardState();
    setState(() {});
    _startJudgementCountdown();
  }

  /// Transitions to [_Phase.calmablesPowerAdjust] and tries to auto-connect
  /// the Calmables device so it is ready for the temperature preference step.
  Future<void> _enterCalmablesPowerAdjust() async {
    if (widget.onConnectCalmables != null) {
      final connected = await widget.onConnectCalmables!();
      if (!connected && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Calmables nicht gefunden – ggf. manuell verbinden'),
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
    if (mounted) setState(() => _phase = _Phase.calmablesPowerAdjust);
  }

  void _startRelaxation() async {
    // For treatment blocks, try to (re-)connect Calmables if not already connected.
    if (_isCurrentBlockTreatment && widget.onConnectCalmables != null) {
      final connected = await widget.onConnectCalmables!();
      if (!connected && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Calmables nicht verbunden – Relaxation ohne Heizung'),
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
    _log('relaxation_start');
    setState(() => _phase = _Phase.relaxationRunning);
    _startPhaseTimer(15 * 60, () {
      if (mounted) setState(() => _phase = _Phase.surveyHintFinal);
    });
  }

  void _restartProtocol() {
    _phaseTimer?.cancel();
    _maJudgementTimer?.cancel();
    _log('protocol_restart');
    setState(() {
      _phase = _Phase.akklimatisation;
      _phaseRemainingSeconds = 0;
      _maCorrectCount = 0;
      _maWrongCount = 0;
    });
  }

  void _onBlockComplete() {
    _log(
        'block_${_currentBlockNumber}_end_${_isCurrentBlockTreatment ? 'treatment' : 'control'}');
    if (_currentBlockNumber == 1) {
      setState(() {
        _currentBlockNumber = 2;
        // _totalMaWrongCount intentionally kept — dashboard score persists across blocks
        _maWrongCount = 0;
        _maCorrectCount = 0;
        _phase = _Phase.akklimatisation;
      });
      _log(
          'block_2_start_${_isCurrentBlockTreatment ? 'treatment' : 'control'}');
    } else {
      setState(() => _phase = _Phase.done);
    }
  }

  void _skipPhase() {
    _phaseTimer?.cancel();
    _maJudgementTimer?.cancel();
    _log('skip_${_phase.name}');
    switch (_phase) {
      case _Phase.calmablesPowerAdjust:
        setState(() => _phase = _Phase.demographicsInput);
      case _Phase.demographicsInput:
        _startAkklimatisation();
      case _Phase.akklimatisation:
        _log('akklimatisation_skip');
        setState(() => _phase = _Phase.baselineReady);
      case _Phase.akklimatisationRunning:
        _log('akklimatisation_skip');
        setState(() => _phase = _Phase.baselineReady);
      case _Phase.baselineReady:
        _log('baseline_end');
        setState(() => _phase = _Phase.surveyHintPreMast);
      case _Phase.baselineRunning:
        _log('baseline_end');
        setState(() => _phase = _Phase.surveyHintPreMast);
      case _Phase.surveyHintPreMast:
        setState(() => _phase = _Phase.mastPrepare);
      // mastPrepare: skip entire MAST
      case _Phase.mastPrepare:
        _log('mast_end');
        setState(() => _phase = _Phase.surveyHintPostMast);
      case _Phase.surveyHintPostMast:
        setState(() => _phase = _Phase.relaxationReady);
      // Individual MAST phases: skip only that phase
      case _Phase.pendingTransition:
        // Always prefer skipCallback if set; otherwise fall back to transitionCallback
        if (_transitionSkipCallback != null) {
          _transitionSkipCallback!.call();
        } else {
          _transitionCallback?.call();
        }
      case _Phase.hit1Running:
        _log('hit_1_end');
        _readyMa1();
      case _Phase.ma1Running:
        _maJudgementTimer?.cancel();
        _judgementAnim?.stop();
        _log('ma_1_end');
        _readyHit2();
      case _Phase.hit2Running:
        _log('hit_2_end');
        _readyMa2();
      case _Phase.ma2Running:
        _maJudgementTimer?.cancel();
        _judgementAnim?.stop();
        _log('ma_2_end');
        _readyHit3();
      case _Phase.hit3Running:
        _log('hit_3_end');
        _readyMa3();
      case _Phase.ma3Running:
        _maJudgementTimer?.cancel();
        _judgementAnim?.stop();
        _log('ma_3_end');
        _readyHit4();
      case _Phase.hit4Running:
        _log('hit_4_end');
        _readyMa4();
      case _Phase.ma4Running:
        _maJudgementTimer?.cancel();
        _judgementAnim?.stop();
        _log('ma_4_end');
        _readyHit5();
      case _Phase.hit5Running:
        _log('hit_5_end');
        _log('mast_end');
        setState(() => _phase = _Phase.surveyHintPostMast);
      case _Phase.relaxationReady:
        _log('relaxation_skip');
        setState(() => _phase = _Phase.surveyHintFinal);
      case _Phase.relaxationRunning:
        _log('relaxation_end');
        setState(() => _phase = _Phase.surveyHintFinal);
      case _Phase.surveyHintFinal:
        if (_isCurrentBlockTreatment) {
          setState(() => _phase = _Phase.questionnaire);
        } else {
          _onBlockComplete();
        }
      case _Phase.questionnaire:
        _onBlockComplete();
      default:
        break;
    }
  }

  void _goBack() {
    _phaseTimer?.cancel();
    _maJudgementTimer?.cancel();
    _log('back_${_phase.name}');
    switch (_phase) {
      case _Phase.calmablesPowerAdjust:
        setState(() => _phase = _Phase.syncDevices);
      case _Phase.demographicsInput:
        setState(() => _phase = _Phase.calmablesPowerAdjust);
      case _Phase.akklimatisation:
        _phaseTimer?.cancel();
        setState(() {
          _phase = _Phase.calmablesPowerAdjust;
          _phaseRemainingSeconds = 0;
        });
      case _Phase.akklimatisationRunning:
        _phaseTimer?.cancel();
        setState(() {
          _phase = _Phase.akklimatisation;
          _phaseRemainingSeconds = 0;
        });
      case _Phase.baselineReady:
        setState(() => _phase = _Phase.akklimatisation);
      case _Phase.baselineRunning:
        setState(() {
          _phase = _Phase.baselineReady;
          _phaseRemainingSeconds = 0;
        });
      case _Phase.surveyHintPreMast:
        setState(() => _phase = _Phase.baselineReady);
      case _Phase.mastPrepare:
        setState(() => _phase = _Phase.surveyHintPreMast);
      case _Phase.surveyHintPostMast:
        setState(() => _phase = _Phase.mastPrepare);
      case _Phase.surveyHintFinal:
        setState(() {
          _phase = _Phase.relaxationReady;
          _phaseRemainingSeconds = 0;
        });
      case _Phase.questionnaire:
        setState(() => _phase = _Phase.surveyHintFinal);
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
      case _Phase.hit4Running:
        _beginMa(3, 90, _readyHit4);
      case _Phase.ma4Running:
        _beginHit(4, 90, _readyMa4);
      case _Phase.hit5Running:
        _beginMa(4, 45, _readyHit5);
      case _Phase.relaxationReady:
        setState(() => _phase = _Phase.surveyHintPostMast);
      case _Phase.relaxationRunning:
        setState(() {
          _phase = _Phase.relaxationReady;
          _phaseRemainingSeconds = 0;
        });
      default:
        break;
    }
  }

  bool get _phaseIsSkippable =>
      _phase != _Phase.participantIdInput &&
      _phase != _Phase.syncDevices &&
      _phase != _Phase.surveyHintPreMast &&
      _phase != _Phase.surveyHintPostMast &&
      _phase != _Phase.surveyHintFinal &&
      _phase != _Phase.questionnaire &&
      _phase != _Phase.done;

  bool get _canGoBack =>
      _phase != _Phase.participantIdInput &&
      _phase != _Phase.syncDevices &&
      _phase != _Phase.done;

  String get _skipLabel {
    if (_phase == _Phase.calmablesPowerAdjust) return 'überspringen';
    if (_phase == _Phase.akklimatisation) return 'Akklimatisation überspringen';
    if (_phase == _Phase.akklimatisationRunning) return 'überspringen';
    if (_phase == _Phase.baselineReady) return 'Baseline überspringen';
    if (_phase == _Phase.baselineRunning) return 'überspringen';
    if (_phase == _Phase.mastPrepare) return 'MAST überspringen';
    if (_phase == _Phase.relaxationReady) return 'Relaxation überspringen';
    if (_phase == _Phase.relaxationRunning) return 'überspringen';
    if (_phase == _Phase.pendingTransition ||
        _phase == _Phase.hit1Running ||
        _phase == _Phase.ma1Running ||
        _phase == _Phase.hit2Running ||
        _phase == _Phase.ma2Running ||
        _phase == _Phase.hit3Running ||
        _phase == _Phase.ma3Running ||
        _phase == _Phase.hit4Running ||
        _phase == _Phase.ma4Running ||
        _phase == _Phase.hit5Running) {
      return 'Phase überspringen';
    }
    return 'Schritt überspringen';
  }

  bool get _isCurrentBlockTreatment =>
      (_blockOrder == _BlockOrder.treatmentFirst) == (_currentBlockNumber == 1);

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
            if (_phase != _Phase.participantIdInput &&
                _phase != _Phase.syncDevices &&
                _phase != _Phase.calmablesPowerAdjust)
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: _isCurrentBlockTreatment
                          ? _kGreen.withValues(alpha: 0.15)
                          : Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: _isCurrentBlockTreatment
                            ? _kGreen
                            : Colors.blue.shade300,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      'Block $_currentBlockNumber · ${_isCurrentBlockTreatment ? 'Treatment' : 'Control'}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: _isCurrentBlockTreatment
                            ? _kGreen
                            : Colors.blue.shade700,
                      ),
                    ),
                  ),
                ),
              ),
            if (_wsAddress != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Center(
                  child: GestureDetector(
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text('WS: ws://$_wsAddress'),
                            duration: const Duration(seconds: 3)),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: _wsClients.isNotEmpty
                            ? _kGreen.withValues(alpha: 0.15)
                            : Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: _wsClients.isNotEmpty
                              ? _kGreen
                              : Colors.grey.shade400,
                          width: 1,
                        ),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(
                          _wsClients.isNotEmpty
                              ? Icons.wifi_rounded
                              : Icons.wifi_off_rounded,
                          size: 14,
                          color: _wsClients.isNotEmpty
                              ? _kGreen
                              : Colors.grey.shade500,
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
            IconButton(
              icon: Icon(
                _showCharts == 0
                    ? Icons.monitor_heart_outlined
                    : Icons.monitor_heart,
              ),
              tooltip: 'Herzrate anzeigen',
              onPressed: _chartsAvailable
                  ? () => setState(() => _showCharts = (_showCharts + 1) % 3)
                  : null,
            ),
            if (showRestartOption)
              TextButton.icon(
                onPressed: _confirmRestartProtocol,
                icon: const Icon(Icons.refresh),
                label: const Text('Restart'),
              ),
          ],
        ),
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          child: Column(
            children: [
              // Protocol content — fixed, no scroll
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildBody(),
                    if (_phaseIsSkippable || _canGoBack) ...[
                      const SizedBox(height: 24),
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
              // Level 1: cards at bottom
              if (_showCharts == 1 && _chartsAvailable) ...[
                const Spacer(),
                _buildMetricCardsRow(),
              ],
              // Level 2: cards fixed + plots scrollable
              if (_showCharts >= 2 && _chartsAvailable) ...[
                _buildMetricCardsRow(),
                Expanded(
                  child: SingleChildScrollView(
                    child: _buildChartPlots(),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetricCardsRow() {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          if (widget.heartRateStream != null)
            Expanded(
              child: StreamBuilder<double?>(
                stream: widget.heartRateStream,
                builder: (ctx, snap) {
                  final bpm = snap.data;
                  return _ChartMetricCard(
                    icon: Icons.favorite_rounded,
                    title: 'Heart Rate',
                    value: bpm != null && bpm.isFinite
                        ? bpm.toStringAsFixed(0)
                        : '--',
                    unit: 'BPM',
                    iconColor: _kGreen,
                  );
                },
              ),
            ),
          if (widget.heartRateStream != null &&
              widget.signalQualityStream != null)
            const SizedBox(width: 12),
          if (widget.signalQualityStream != null)
            Expanded(
              child: StreamBuilder<PpgSignalQuality>(
                stream: widget.signalQualityStream,
                initialData: PpgSignalQuality.unavailable,
                builder: (ctx, snap) {
                  final q = snap.data ?? PpgSignalQuality.unavailable;
                  final cs = Theme.of(ctx).colorScheme;
                  final (label, _, icon, color) = switch (q) {
                    PpgSignalQuality.good => (
                        'Good',
                        'Signal quality is good.',
                        Icons.check_circle_rounded,
                        const Color(0xFF8CB63C)
                      ),
                    PpgSignalQuality.fair => (
                        'Fair',
                        'Heartbeat is visible.',
                        Icons.network_check_rounded,
                        Colors.orange.shade700
                      ),
                    PpgSignalQuality.bad => (
                        'Bad',
                        'Signal is noisy.',
                        Icons
                            .signal_cellular_connected_no_internet_4_bar_rounded,
                        cs.error
                      ),
                    PpgSignalQuality.unavailable => (
                        'Unavailable',
                        'No stable heartbeat.',
                        Icons.portable_wifi_off_rounded,
                        cs.onSurfaceVariant
                      ),
                  };
                  return CalmablesCardShell(
                    padding: calmablesSmallCardPadding,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CalmablesCompactHeader(
                          icon: icon,
                          title: 'PPG',
                          accentColor: color,
                        ),
                        const Spacer(),
                        CalmablesStatusChip(
                          label: label,
                          color: color,
                          dense: true,
                          textStyle:
                              Theme.of(ctx).textTheme.titleSmall?.copyWith(
                                    fontSize: 18,
                                  ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildChartPlots() {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // HR chart card
          if (_showCharts >= 2 &&
              widget.rawHrStream != null &&
              widget.smoothedHrStream != null) ...[
            const SizedBox(height: 10),
            CalmablesCardShell(
              padding: calmablesCompactCardPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const CalmablesCardHeader(
                    icon: Icons.favorite_rounded,
                    title: 'Heart Rate (60s)',
                    subtitle: 'Grau: RR-Intervall HR · Rot: Kalman-gefiltert',
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 120,
                    child: RollingHrChart(
                      rawHrStream: widget.rawHrStream!,
                      smoothedHrStream: widget.smoothedHrStream!,
                      timestampExponent: widget.timestampExponent,
                      timeWindow: 60,
                    ),
                  ),
                ],
              ),
            ),
          ],
          // PPG chart card
          if (widget.displayPpgStream != null) ...[
            const SizedBox(height: 10),
            CalmablesCardShell(
              padding: calmablesCompactCardPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const CalmablesCardHeader(
                    icon: Icons.show_chart_rounded,
                    title: 'PPG Signal',
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 88,
                    child: RollingChart(
                      dataSteam: widget.displayPpgStream!,
                      timestampExponent: widget.timestampExponent,
                      timeWindow: 5,
                      showXAxis: false,
                      showYAxis: false,
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

  Widget _buildBody() {
    return switch (_phase) {
      _Phase.participantIdInput => _buildParticipantIdInput(),
      _Phase.syncDevices => _buildSyncDevices(),
      _Phase.calmablesPowerAdjust => _buildCalmablesPowerAdjust(),
      _Phase.demographicsInput => _buildDemographicsInput(),
      _Phase.akklimatisation => _buildAkklimatisation(),
      _Phase.akklimatisationRunning => _buildAkklimatisationRunning(),
      _Phase.baselineReady => _buildBaselineReady(),
      _Phase.baselineRunning => _buildBaselineRunning(),
      _Phase.surveyHintPreMast => _buildSurveyHint(
          nextPhase: _Phase.mastPrepare,
          nextLabel: 'Weiter zum MAST',
          showUxHint: false,
        ),
      _Phase.mastPrepare => _buildMastPrepare(),
      _Phase.pendingTransition => _buildTransitionReady(),
      _Phase.hit1Running => _buildHitPhase(1, 90),
      _Phase.ma1Running => _buildMaPhase(1, 45),
      _Phase.hit2Running => _buildHitPhase(2, 60),
      _Phase.ma2Running => _buildMaPhase(2, 60),
      _Phase.hit3Running => _buildHitPhase(3, 60),
      _Phase.ma3Running => _buildMaPhase(3, 90),
      _Phase.hit4Running => _buildHitPhase(4, 90),
      _Phase.ma4Running => _buildMaPhase(4, 45),
      _Phase.hit5Running => _buildHitPhase(5, 60),
      _Phase.surveyHintPostMast => _buildSurveyHint(
          nextPhase: _Phase.relaxationReady,
          nextLabel: 'Weiter zur Entspannung',
          showUxHint: false,
        ),
      _Phase.relaxationReady => _buildRelaxationReady(),
      _Phase.relaxationRunning => _buildRelaxationRunning(),
      _Phase.surveyHintFinal => _buildSurveyHint(
          nextPhase: _Phase.questionnaire,
          nextLabel: _isCurrentBlockTreatment
              ? 'Weiter zum UX-Fragebogen'
              : 'Block abschließen',
          showUxHint: _isCurrentBlockTreatment,
          onNext: _isCurrentBlockTreatment ? null : _onBlockComplete,
        ),
      _Phase.questionnaire => _buildQuestionnaire(),
      _Phase.done => _buildDone(),
    };
  }

  // ── Phase widgets ─────────────────────────────────────────────────────────────

  Widget _buildParticipantIdInput() {
    return SingleChildScrollView(
      child: Column(
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
          // Block order selection
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Studienreihenfolge',
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: Colors.grey.shade700),
            ),
          ),
          const SizedBox(height: 10),
          SegmentedButton<_BlockOrder>(
            segments: const [
              ButtonSegment(
                value: _BlockOrder.treatmentFirst,
                label: Text('Treatment zuerst'),
                icon: Icon(Icons.thermostat_rounded),
              ),
              ButtonSegment(
                value: _BlockOrder.controlFirst,
                label: Text('Control zuerst'),
                icon: Icon(Icons.science_outlined),
              ),
            ],
            selected: {_blockOrder},
            onSelectionChanged: (s) => setState(() => _blockOrder = s.first),
          ),
          const SizedBox(height: 8),
          Text(
            _blockOrder == _BlockOrder.treatmentFirst
                ? 'Block 1: Treatment · Block 2: Control'
                : 'Block 1: Control · Block 2: Treatment',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () async {
                final id = _participantIdController.text.trim();
                if (id.isEmpty) return;
                _log('study_order_${_blockOrder.name}');
                await _startRecording(id);
              },
              icon: const Icon(Icons.fiber_manual_record),
              label: const Text('Aufnahme starten & Protokoll beginnen'),
              style: _primaryStyle(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransitionReady() {
    return Column(
      children: [
        const SizedBox(height: 48),
        Icon(_transitionIcon, size: 72, color: _kGreen),
        const SizedBox(height: 24),
        _phaseTitle(_transitionTitle),
        if (_transitionIsMa) ...[
          const SizedBox(height: 16),
          Text(
            'Startzahl',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey),
          ),
          const SizedBox(height: 4),
          Text(
            '$_maStartNumber',
            style: Theme.of(context).textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: _kGreen,
                  letterSpacing: 4,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            'VP nennt diese Zahl, dann fortlaufend −17',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ] else
          const SizedBox(height: 8),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _transitionCallback ?? () {},
            icon: Icon(_transitionIcon),
            label: Text(_transitionButtonLabel),
            style: _primaryStyle(),
          ),
        ),
      ],
    );
  }

  Widget _buildAkklimatisation() => _buildReadyScreen(
        icon: Icons.air_rounded,
        title: 'Akklimatisation',
        description:
            'Versuchsperson 15 Minuten akklimatisieren lassen. Bitte sicherstellen, dass die Person ruhig sitzt und entspannt ist.',
        buttonLabel: 'Akklimatisation starten',
        onStart: _startAkklimatisation,
      );

  Widget _buildBaselineReady() => _buildReadyScreen(
        icon: Icons.self_improvement_rounded,
        title: 'Baseline',
        description:
            'Bitte stellen Sie sicher, dass die Versuchsperson ruhig sitzt und entspannt ist.',
        buttonLabel: 'Baseline starten',
        onStart: _startBaseline,
      );

  Widget _buildAkklimatisationRunning() {
    return Column(
      children: [
        const SizedBox(height: 48),
        _phaseTitle('Akklimatisation'),
        const SizedBox(height: 40),
        _timerDisplay(_phaseRemainingSeconds),
        const SizedBox(height: 40),
        OutlinedButton.icon(
          onPressed: () {
            _phaseTimer?.cancel();
            setState(() {
              _phase = _Phase.akklimatisation;
              _phaseRemainingSeconds = 0;
            });
          },
          icon: const Icon(Icons.refresh),
          label: const Text('Akklimatisation neu starten'),
        ),
      ],
    );
  }

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

  Widget _buildSurveyHint({
    required _Phase nextPhase,
    required String nextLabel,
    required bool showUxHint,
    VoidCallback? onNext,
  }) {
    return Column(
      children: [
        const SizedBox(height: 48),
        const Icon(Icons.assignment_turned_in_rounded,
            size: 72, color: _kGreen),
        const SizedBox(height: 24),
        _phaseTitle('Survey ausfüllen'),
        const SizedBox(height: 16),
        Text(
          showUxHint
              ? 'Bitte die Versuchsperson auffordern, jetzt die Survey auszufüllen.\n\nAnschließend folgt der UX-Fragebogen.'
              : 'Bitte die Versuchsperson auffordern, jetzt die Survey auszufüllen.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 40),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: onNext ?? () => setState(() => _phase = nextPhase),
            style: _primaryStyle(),
            child: Text(nextLabel),
          ),
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
            onPressed: _onBlockComplete,
            style: _primaryStyle(),
            child: const Text('Protokoll abschließen'),
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
    final isFirstQuestion = _maExpectedAnswer == _maStartNumber;
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
        // Question label
        Text(
          isFirstQuestion
              ? 'VP nennt die Startzahl'
              : '$_maCurrentNumber − 17 = ?',
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: Colors.grey),
        ),
        const SizedBox(height: 4),
        Text(
          isFirstQuestion ? 'Erwartete Nennung' : 'Erwartete Antwort',
          style: const TextStyle(color: Colors.grey, fontSize: 14),
        ),
        const SizedBox(height: 8),
        Text(
          '$_maExpectedAnswer',
          style: Theme.of(context).textTheme.displayLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: isFirstQuestion ? _kGreen : Colors.orange.shade700,
              ),
        ),
        const SizedBox(height: 8),
        // Smooth judgement countdown ring
        if (_judgementAnim != null)
          AnimatedBuilder(
            animation: _judgementAnim!,
            builder: (ctx, _) {
              final fraction = _judgementAnim!.value;
              final secondsLeft = (fraction * 5).ceil().clamp(0, 5);
              return SizedBox(
                width: 56,
                height: 56,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: fraction,
                      strokeWidth: 5,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: AlwaysStoppedAnimation(
                        fraction <= 0.4 ? Colors.red : Colors.orange.shade600,
                      ),
                    ),
                    Text(
                      '$secondsLeft',
                      style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ],
                ),
              );
            },
          )
        else
          const SizedBox(width: 56, height: 56),
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
        title: _isCurrentBlockTreatment
            ? 'Relaxationsphase – Treatment'
            : 'Relaxationsphase – Control',
        description: _isCurrentBlockTreatment
            ? 'MAST abgeschlossen.\nBitte Versuchsperson zur Entspannung auffordern.\nCalmables wird während der Entspannung aktiv.'
            : 'MAST abgeschlossen.\nBitte Versuchsperson zur Entspannung auffordern.\nKein Calmables-Treatment in dieser Phase.',
        buttonLabel: 'Relaxation starten (15 min)',
        onStart: _startRelaxation,
      );

  Widget _buildRelaxationRunning() {
    return Column(
      children: [
        const SizedBox(height: 32),
        _phaseTitle(_isCurrentBlockTreatment
            ? 'Relaxation \u2013 Treatment'
            : 'Relaxation \u2013 Control'),
        const SizedBox(height: 16),
        _timerDisplay(_phaseRemainingSeconds),
        const SizedBox(height: 24),
        if (_isCurrentBlockTreatment)
          _buildCalmablesControlPanel(showSavedValueMarker: true)
        else
          Opacity(
            opacity: 0.38,
            child: IgnorePointer(
              child: _buildCalmablesControlPanel(showSavedValueMarker: false),
            ),
          ),
        if (!_isCurrentBlockTreatment) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.info_outline_rounded,
                  size: 14, color: Colors.grey.shade500),
              const SizedBox(width: 6),
              Text(
                'Control-Phase: Calmables deaktiviert',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
            ],
          ),
        ],
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
          'Alle Phasen beendet. Bitte folgende Schritte durchführen:',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 24),
        _buildSyncStep('1', Icons.monitor_heart_outlined, 'EKG stoppen'),
        const SizedBox(height: 12),
        _buildSyncStep('2', Icons.device_hub_rounded, 'RespiBAN stoppen'),
        const SizedBox(height: 12),
        _buildSyncStep('3', Icons.watch_rounded, 'Calmables Aufnahme beenden'),
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
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _confirmRestartProtocol,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Protokoll neu starten'),
          ),
        ),
      ],
    );
  }

  // ── Shared helpers ────────────────────────────────────────────────────────────

  Widget _buildSyncDevices() {
    return Column(
      children: [
        const SizedBox(height: 48),
        const Icon(Icons.sync_rounded, size: 72, color: _kGreen),
        const SizedBox(height: 24),
        _phaseTitle('Geräte synchronisieren'),
        const SizedBox(height: 24),
        _buildSyncStep('1', Icons.monitor_heart_outlined, 'EKG starten'),
        const SizedBox(height: 12),
        _buildSyncStep('2', Icons.device_hub_rounded, 'RespiBAN starten'),
        const SizedBox(height: 12),
        _buildSyncStep(
          '3',
          Icons.back_hand_outlined,
          'Probanden auffordern, mit dem Ring auf das RespiBAN zu schlagen – gleichzeitig den PPG-Sensor des EKG-Geräts abziehen',
        ),
        const SizedBox(height: 12),
        _buildSyncStep(
          '4',
          Icons.touch_app_rounded,
          'Danach möglichst zügig auf „Weiter" tippen',
        ),
        const SizedBox(height: 40),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _enterCalmablesPowerAdjust,
            icon: const Icon(Icons.check_rounded),
            label: const Text('Geräte synchronisiert – Weiter'),
            style: _primaryStyle(),
          ),
        ),
      ],
    );
  }

  Widget _buildSyncStep(String number, IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: _kGreen,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            number,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Icon(icon, size: 22, color: _kGreen),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 15),
          ),
        ),
      ],
    );
  }

  Widget _buildCalmablesPowerAdjust() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 32),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.tune_rounded, size: 36, color: _kGreen),
            const SizedBox(width: 12),
            _phaseTitle('Calmables einstellen'),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Stelle die Heizleistung ein, die für die Relaxationsphase verwendet werden soll.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15),
        ),
        const SizedBox(height: 24),
        _buildCalmablesControlPanel(showSavedValueMarker: false),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () {
              _calmablesPowerValue = _relaxationCurrentPwm;
              _log('calmables_power_set_$_calmablesPowerValue');
              setState(() => _phase = _Phase.demographicsInput);
            },
            icon: const Icon(Icons.check_rounded),
            label: const Text('Wert speichern & weiter'),
            style: _primaryStyle(),
          ),
        ),
      ],
    );
  }

  Widget _buildDemographicsInput() {
    return Column(
      children: [
        const SizedBox(height: 48),
        const Icon(Icons.assignment_ind_outlined, size: 72, color: _kGreen),
        const SizedBox(height: 24),
        _phaseTitle('Demografische Daten'),
        const SizedBox(height: 16),
        const Text(
          'Bitte den Probanden auffordern, den Demografiefragebogen auszufüllen.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 40),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _startAkklimatisation,
            icon: const Icon(Icons.check_rounded),
            label: const Text('Fragebogen ausgefüllt – zur Akklimatisation'),
            style: _primaryStyle(),
          ),
        ),
      ],
    );
  }

  Widget _buildCalmablesControlPanel({required bool showSavedValueMarker}) {
    if (widget.onSendToCalmables == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Kein Calmables-Gerät verbunden.',
          style: TextStyle(color: Colors.grey),
          textAlign: TextAlign.center,
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bolt_rounded, size: 18, color: _kGreen),
                const SizedBox(width: 6),
                Text(
                  'Calmables Control',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                // On/Off toggle
                Row(
                  children: [
                    Text(_calmablesOn ? 'ON' : 'OFF',
                        style: TextStyle(
                          color: _calmablesOn ? _kGreen : Colors.grey,
                          fontWeight: FontWeight.w600,
                        )),
                    const SizedBox(width: 6),
                    Switch(
                      value: _calmablesOn,
                      activeColor: _kGreen,
                      activeTrackColor: _kGreen.withOpacity(0.35),
                      trackOutlineColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.selected)
                            ? _kGreen
                            : Colors.grey.shade400,
                      ),
                      onChanged: (v) {
                        setState(() => _calmablesOn = v);
                        final pwm = v ? _relaxationCurrentPwm : 0;
                        widget.onSendToCalmables!([pwm]);
                      },
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Slider
            Row(
              children: [
                const Text('0',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
                Expanded(
                  child: LayoutBuilder(
                    builder: (ctx, constraints) {
                      const sliderPad = 24.0;
                      final trackWidth = constraints.maxWidth - 2 * sliderPad;
                      final markerX = sliderPad +
                          (_calmablesPowerValue / 255.0) * trackWidth;
                      final alignment = 2 * markerX / constraints.maxWidth - 1;
                      return Stack(
                        children: [
                          if (showSavedValueMarker && _calmablesPowerValue > 0)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: Align(
                                  alignment: Alignment(alignment, 0),
                                  child: Container(
                                    width: 2,
                                    height: 36,
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                              ),
                            ),
                          Slider(
                            value: _relaxationCurrentPwm.toDouble(),
                            min: 0,
                            max: 255,
                            divisions: 255,
                            label: _relaxationCurrentPwm.toString(),
                            activeColor: _kGreen,
                            thumbColor: _kGreen,
                            onChanged: (v) {
                              setState(() {
                                _relaxationCurrentPwm = v.round();
                                if (_calmablesOn)
                                  widget.onSendToCalmables!(
                                      [_relaxationCurrentPwm]);
                              });
                            },
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const Text('255',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                'Leistung: $_relaxationCurrentPwm / 255'
                '${showSavedValueMarker && _calmablesPowerValue > 0 ? "  ·  Gespeichert: $_calmablesPowerValue" : ""}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

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

class _ChartMetricCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final String unit;
  final Color iconColor;

  const _ChartMetricCard({
    required this.icon,
    required this.title,
    required this.value,
    required this.unit,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return CalmablesCardShell(
      padding: calmablesSmallCardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CalmablesCompactHeader(
            icon: icon,
            title: title,
            accentColor: iconColor,
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(value,
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  unit,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
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
