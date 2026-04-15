import 'dart:async';
import 'dart:math';

import 'package:open_wearable/apps/calmables/model/ppg_filter.dart';

class _TimestampedSample {
  final DateTime time;
  final double heartRate;
  final PpgSignalQuality quality;

  _TimestampedSample({
    required this.time,
    required this.heartRate,
    required this.quality,
  });
}

class CalibrationResult {
  final double baselineHeartRate;
  final double triggerThreshold;
  final double windowStd;

  const CalibrationResult({
    required this.baselineHeartRate,
    required this.triggerThreshold,
    required this.windowStd,
  });
}

class HrCalibration {
  static const Duration calibrationDuration = Duration(minutes: 5);
  static const Duration windowDuration = Duration(seconds: 30);
  static const double _minGoodQualityRatio = 0.80;
  static const double _maxStabilityCoefficient = 0.10;

  StreamSubscription<double?>? _hrSubscription;
  StreamSubscription<PpgSignalQuality>? _qualitySubscription;

  final List<_TimestampedSample> _samples = [];
  PpgSignalQuality _currentQuality = PpgSignalQuality.unavailable;

  bool _isCalibrating = false;
  bool get isCalibrating => _isCalibrating;

  DateTime? _startTime;
  DateTime? get startTime => _startTime;

  CalibrationResult? _latestResult;
  CalibrationResult? get latestResult => _latestResult;

  void Function(CalibrationResult?)? onResultUpdated;
  void Function()? onCalibrationFinished;

  double get elapsedSeconds {
    if (_startTime == null) return 0;
    return DateTime.now().difference(_startTime!).inMilliseconds / 1000.0;
  }

  double get progressFraction {
    return (elapsedSeconds / calibrationDuration.inSeconds).clamp(0.0, 1.0);
  }

  void start({
    required Stream<double?> heartRateStream,
    required Stream<PpgSignalQuality> signalQualityStream,
  }) {
    if (_isCalibrating) return;

    _samples.clear();
    _latestResult = null;
    _isCalibrating = true;
    _startTime = DateTime.now();

    _qualitySubscription = signalQualityStream.listen((quality) {
      _currentQuality = quality;
    });

    _hrSubscription = heartRateStream.listen((hr) {
      if (!_isCalibrating) return;
      if (hr == null || !hr.isFinite) return;

      _samples.add(_TimestampedSample(
        time: DateTime.now(),
        heartRate: hr,
        quality: _currentQuality,
      ));

      _evaluate();

      if (DateTime.now().difference(_startTime!) >= calibrationDuration) {
        stop();
        onCalibrationFinished?.call();
      }
    });
  }

  void stop() {
    _isCalibrating = false;
    _hrSubscription?.cancel();
    _hrSubscription = null;
    _qualitySubscription?.cancel();
    _qualitySubscription = null;
  }

  static const Duration _windowStep = Duration(seconds: 5);

  void _evaluate() {
    final now = DateTime.now();
    final start = _startTime!;

    CalibrationResult? bestResult;

    // Slide through completed 30s windows with 5s step for responsive updates.
    var windowStart = start;
    while (windowStart.add(windowDuration).isBefore(now) ||
        windowStart.add(windowDuration).isAtSameMomentAs(now)) {
      final windowEnd = windowStart.add(windowDuration);

      final windowSamples = _samples
          .where((s) =>
              !s.time.isBefore(windowStart) && s.time.isBefore(windowEnd))
          .toList();

      if (windowSamples.length >= 2) {
        final result = _evaluateWindow(windowSamples);
        if (result != null) {
          if (bestResult == null ||
              result.baselineHeartRate < bestResult.baselineHeartRate) {
            bestResult = result;
          }
        }
      }

      windowStart = windowStart.add(_windowStep);
    }

    final changed = bestResult == null
        ? _latestResult != null
        : _latestResult == null ||
            (bestResult.baselineHeartRate - _latestResult!.baselineHeartRate)
                    .abs() >
                0.05 ||
            (bestResult.triggerThreshold - _latestResult!.triggerThreshold)
                    .abs() >
                0.05;
    if (changed) {
      _latestResult = bestResult;
      onResultUpdated?.call(bestResult);
    }
  }

  CalibrationResult? _evaluateWindow(List<_TimestampedSample> samples) {
    // Check quality: >= 80% good
    final goodCount =
        samples.where((s) => s.quality == PpgSignalQuality.good).length;
    final goodRatio = goodCount / samples.length;
    if (goodRatio < _minGoodQualityRatio) return null;

    // Check stability: coefficient of variation <= 10%
    final hrs = samples.map((s) => s.heartRate).toList();
    final mean = hrs.reduce((a, b) => a + b) / hrs.length;
    if (mean <= 0) return null;

    var sumSq = 0.0;
    for (final hr in hrs) {
      final d = hr - mean;
      sumSq += d * d;
    }
    final std = sqrt(sumSq / hrs.length);
    final cv = std / mean;

    if (cv > _maxStabilityCoefficient) return null;

    return CalibrationResult(
      baselineHeartRate: mean,
      triggerThreshold: mean + 3 * std,
      windowStd: std,
    );
  }
}
