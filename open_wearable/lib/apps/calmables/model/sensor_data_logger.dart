import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:open_wearable/apps/calmables/model/ppg_filter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class SensorDataLogger {
  StreamSubscription<PpgOpticalSample>? _ppgSubscription;
  StreamSubscription<PpgMotionSample>? _imuSubscription;
  StreamSubscription<double?>? _hrSubscription;
  StreamSubscription<double?>? _lfhfSubscription;

  IOSink? _ppgSink;
  IOSink? _imuSink;
  IOSink? _metricsSink;
  File? _ppgFile;
  File? _imuFile;
  File? _metricsFile;

  double? _lastHr;
  double? _lastLfhf;

  bool _isLogging = false;
  bool get isLogging => _isLogging;

  int _ppgSampleCount = 0;
  int _imuSampleCount = 0;
  int get ppgSampleCount => _ppgSampleCount;
  int get imuSampleCount => _imuSampleCount;

  Future<void> start({
    required Stream<PpgOpticalSample> ppgStream,
    Stream<PpgMotionSample>? imuStream,
    Stream<double?>? heartRateStream,
    Stream<double?>? lfhfStream,
  }) async {
    if (_isLogging) return;

    final dir = await getApplicationDocumentsDirectory();
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final sessionDir = Directory('${dir.path}/calmables_logs/$timestamp');
    await sessionDir.create(recursive: true);

    _ppgFile = File('${sessionDir.path}/ppg_$timestamp.csv');
    _ppgSink = _ppgFile!.openWrite();
    _ppgSink!.writeln('timestamp,red,ir,green,ambient');

    _ppgSampleCount = 0;
    _imuSampleCount = 0;
    _lastHr = null;
    _lastLfhf = null;

    _ppgSubscription = ppgStream.listen((sample) {
      _ppgSink?.writeln(
        '${sample.timestamp},${sample.red},${sample.ir},${sample.green},${sample.ambient}',
      );
      _ppgSampleCount++;
    });

    if (imuStream != null) {
      _imuFile = File('${sessionDir.path}/imu_$timestamp.csv');
      _imuSink = _imuFile!.openWrite();
      _imuSink!.writeln('timestamp,x,y,z');

      _imuSubscription = imuStream.listen((sample) {
        _imuSink?.writeln(
          '${sample.timestamp},${sample.x},${sample.y},${sample.z}',
        );
        _imuSampleCount++;
      });
    }

    _metricsFile = File('${sessionDir.path}/metrics_$timestamp.csv');
    _metricsSink = _metricsFile!.openWrite();
    _metricsSink!.writeln('epoch_ms,heart_rate_bpm,lfhf_ratio,pwm');

    if (heartRateStream != null) {
      _hrSubscription = heartRateStream.listen((hr) {
        _lastHr = hr;
      });
    }
    if (lfhfStream != null) {
      _lfhfSubscription = lfhfStream.listen((lfhf) {
        _lastLfhf = lfhf;
      });
    }

    _isLogging = true;
    debugPrint('SensorDataLogger: started logging to ${sessionDir.path}');
  }

  Future<List<String>> stop() async {
    if (!_isLogging) return [];
    _isLogging = false;

    await _ppgSubscription?.cancel();
    _ppgSubscription = null;
    await _imuSubscription?.cancel();
    _imuSubscription = null;
    await _hrSubscription?.cancel();
    _hrSubscription = null;
    await _lfhfSubscription?.cancel();
    _lfhfSubscription = null;

    await _ppgSink?.flush();
    await _ppgSink?.close();
    _ppgSink = null;

    await _imuSink?.flush();
    await _imuSink?.close();
    _imuSink = null;

    await _metricsSink?.flush();
    await _metricsSink?.close();
    _metricsSink = null;

    final files = <String>[];
    if (_ppgFile != null) files.add(_ppgFile!.path);
    if (_imuFile != null) files.add(_imuFile!.path);
    if (_metricsFile != null) files.add(_metricsFile!.path);

    debugPrint(
      'SensorDataLogger: stopped. PPG samples: $_ppgSampleCount, IMU samples: $_imuSampleCount',
    );
    return files;
  }

  void logMetrics({required int pwm}) {
    if (!_isLogging) return;
    final epochMs = DateTime.now().millisecondsSinceEpoch;
    final hr = _lastHr?.toStringAsFixed(1) ?? '';
    final lfhf = _lastLfhf?.toStringAsFixed(3) ?? '';
    _metricsSink?.writeln('$epochMs,$hr,$lfhf,$pwm');
  }

  Future<void> stopAndShare() async {
    final files = await stop();
    if (files.isEmpty) return;

    final xFiles = files.map((path) => XFile(path)).toList();
    await SharePlus.instance.share(
      ShareParams(files: xFiles),
    );
  }
}
