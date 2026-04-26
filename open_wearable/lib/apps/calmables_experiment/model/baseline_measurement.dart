import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';

class MeasurementManager {
  Recorder? _pwmRecorder;
  Recorder? _ppgRecorder;
  Recorder? _hrRecorder;

  Timer? _timer;
  DateTime? _startTime;
  bool _isMeasuring = false;
  bool get isMeasuring => _isMeasuring;

  String elapsedTimeStr = "00:00";

  String? lastPwmFilePath;
  String? lastPpgFilePath;
  String? lastHrFilePath;

  void Function()? onUpdate;

  Future<void> startMeasurement({
    required Stream<int> pwmStream,
    required Stream<(int, double)> ppgStream,
    required Stream<double> heartRateStream,
  }) async {
    if (_isMeasuring) return;
    _isMeasuring = true;
    _startTime = DateTime.now();
    elapsedTimeStr = "00:00";

    final directory = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    lastPwmFilePath = '${directory.path}/pwm_$timestamp.csv';
    lastPpgFilePath = '${directory.path}/ppg_$timestamp.csv';
    lastHrFilePath = '${directory.path}/heart_rate_$timestamp.csv';

    // Stream<SensorValue>に変換
    Stream<SensorValue> pwmSensorValueStream = pwmStream.map((pwm) {
      return SensorValue(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        valueStrings: [pwm.toString()],
      );
    });

    Stream<SensorValue> ppgSensorValueStream = ppgStream.map((tuple) {
      final timestampMs = tuple.$1;
      final ppgVal = tuple.$2;
      return SensorValue(
        timestamp: timestampMs,
        valueStrings: [ppgVal.toStringAsFixed(3)],
      );
    });

    Stream<SensorValue> hrSensorValueStream = heartRateStream.map((hr) {
      return SensorValue(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        valueStrings: [hr.toStringAsFixed(1)],
      );
    });

    // Recorder開始
    _pwmRecorder = Recorder(columns: ['PWM']);
    await _pwmRecorder!.start(
      filepath: lastPwmFilePath!,
      inputStream: pwmSensorValueStream,
    );

    _ppgRecorder = Recorder(columns: ['PPG']);
    await _ppgRecorder!.start(
      filepath: lastPpgFilePath!,
      inputStream: ppgSensorValueStream,
    );

    _hrRecorder = Recorder(columns: ['HeartRate']);
    await _hrRecorder!.start(
      filepath: lastHrFilePath!,
      inputStream: hrSensorValueStream,
    );

    // 経過時間更新タイマー
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final elapsed = DateTime.now().difference(_startTime!);
      final minutes = elapsed.inMinutes;
      final seconds = elapsed.inSeconds % 60;
      elapsedTimeStr =
          '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
      onUpdate?.call();
    });
    onUpdate?.call();
  }

  Future<void> stopMeasurement() async {
    if (!_isMeasuring) return;
    _timer?.cancel();
    _timer = null;

    // stop()はvoidなので戻り値を使わずにawaitするだけ
    _pwmRecorder?.stop();
    _ppgRecorder?.stop();
    _hrRecorder?.stop();

    _pwmRecorder = null;
    _ppgRecorder = null;
    _hrRecorder = null;

    _isMeasuring = false;
    onUpdate?.call();
  }
}
