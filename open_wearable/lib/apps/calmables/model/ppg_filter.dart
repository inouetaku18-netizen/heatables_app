// ignore_for_file: cancel_subscriptions

import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'package:flutter/foundation.dart';

import 'package:open_wearable/apps/calmables/model/band_pass_filter.dart';
import 'package:open_wearable/apps/calmables/model/high_pass_filter.dart';
import 'package:open_wearable/apps/calmables/model/hrv_lfhf.dart';

// ---------------------------------------------------------------------------
// Top-level types & function for background isolate computation (Fix 4 + 5).
// ---------------------------------------------------------------------------

class _VitalsComputeInput {
  final List<double> signals;
  final List<double> motionLevels;
  final List<int> timestamps;
  final int latestTimestamp;
  final double ticksPerSecond;
  final double sampleFreq;
  final double minBeatIntervalSec;
  final double maxBeatIntervalSec;

  const _VitalsComputeInput({
    required this.signals,
    required this.motionLevels,
    required this.timestamps,
    required this.latestTimestamp,
    required this.ticksPerSecond,
    required this.sampleFreq,
    required this.minBeatIntervalSec,
    required this.maxBeatIntervalSec,
  });
}

class _VitalsComputeResult {
  final double qualityScore;
  final double averageMotion;
  final double? peakHeartRate;
  final List<int> peakTimestamps;
  final List<double> ibiTicks;
  final double? peakToMedianRatio;
  final int peakCount;
  final int peakWindowSamples;
  final String debugReason;

  const _VitalsComputeResult({
    required this.qualityScore,
    required this.averageMotion,
    required this.peakHeartRate,
    required this.peakTimestamps,
    required this.ibiTicks,
    required this.peakToMedianRatio,
    required this.peakCount,
    required this.peakWindowSamples,
    required this.debugReason,
  });
}

/// Runs entirely in a background isolate via [compute].
_VitalsComputeResult _evaluateVitalsIsolated(_VitalsComputeInput input) {
  final signals = input.signals;
  final motionLevels = input.motionLevels;
  final timestamps = input.timestamps;
  final n = signals.length;
  final tps = input.ticksPerSecond;

  // ── Quality scoring (recent 3 s window) ──────────────────────────────────
  final qualityWindowTicks = 3.0 * tps;
  final latestTs = input.latestTimestamp;
  final cutoffTs = latestTs - qualityWindowTicks;

  var recentStart = n;
  for (var i = n - 1; i >= 0; i--) {
    if (timestamps[i] < cutoffTs) break;
    recentStart = i;
  }
  final recentCount = n - recentStart;
  final minimumSamples = max(8, (input.sampleFreq * 1.2).round());

  double qualityScore;
  double averageMotion;
  double? peakToMedianRatio;
  var peakCount = 0;
  var peakWindowSamples = 0;
  final reasons = StringBuffer();

  if (recentCount < minimumSamples) {
    qualityScore = 0.0;
    averageMotion = 0.0;
    reasons.write('too few recent samples ($recentCount < $minimumSamples)');
  } else {
    var sumAbs = 0.0;
    var minS = double.infinity;
    var maxS = double.negativeInfinity;
    var sumMotion = 0.0;
    var sumS = 0.0;
    var sumSSq = 0.0;

    for (var i = recentStart; i < n; i++) {
      final s = signals[i];
      sumAbs += s.abs();
      if (s < minS) minS = s;
      if (s > maxS) maxS = s;
      sumMotion += motionLevels[i];
      sumS += s;
      sumSSq += s * s;
    }

    final meanAbs = sumAbs / recentCount;
    averageMotion = sumMotion / recentCount;

    if (!meanAbs.isFinite || meanAbs <= 1e-6) {
      qualityScore = 0.0;
      reasons.write('meanAbs too low (${meanAbs.toStringAsFixed(6)})');
    } else {
      final rangeS = maxS - minS;
      final meanS = sumS / recentCount;
      final variance = (sumSSq / recentCount) - (meanS * meanS);
      final stdS = variance > 0 ? sqrt(variance) : 0.0;

      final rangeScore = ((rangeS - 0.08) / 0.95).clamp(0.0, 1.0);
      final stdScore = ((stdS - 0.025) / 0.30).clamp(0.0, 1.0);
      final motionScore = (1.0 - (averageMotion / 2.2)).clamp(0.0, 1.0);

      qualityScore =
          ((0.45 * rangeScore) + (0.35 * stdScore) + (0.20 * motionScore))
              .clamp(0.0, 1.0);

      reasons.write('range=${rangeS.toStringAsFixed(3)} '
          'rangeScore=${rangeScore.toStringAsFixed(2)}, '
          'std=${stdS.toStringAsFixed(3)} '
          'stdScore=${stdScore.toStringAsFixed(2)}, '
          'motion=${averageMotion.toStringAsFixed(2)} '
          'motionScore=${motionScore.toStringAsFixed(2)}, '
          'waveformQ=${qualityScore.toStringAsFixed(2)}');

      /*if (averageMotion >= 1.45) {
        qualityScore = min(qualityScore, 0.10);
        reasons.write(' → clamped to 0.10 (motion>=1.45)');
      } else if (averageMotion >= 1.12) {
        qualityScore = min(qualityScore, 0.24);
        reasons.write(' → clamped to 0.24 (motion>=1.12)');
      } else if (averageMotion >= 0.88) {
        qualityScore = min(qualityScore, 0.45);
        reasons.write(' → clamped to 0.45 (motion>=0.88)');
      }*/
    }
  }

  // ── Effective sample frequency ────────────────────────────────────────────
  double effectiveSampleFreqHz;
  if (n < 2) {
    effectiveSampleFreqHz = input.sampleFreq;
  } else {
    final durationTicks = (timestamps.last - timestamps.first).toDouble();
    if (durationTicks <= 0) {
      effectiveSampleFreqHz = input.sampleFreq;
    } else {
      final est = ((n - 1) * tps) / durationTicks;
      effectiveSampleFreqHz =
          (est.isFinite && est >= 5 && est <= 200) ? est : input.sampleFreq;
    }
  }

  // ── MSPTD fast peak detection ──────────────────────────────────────────────
  // Modified Scalogram-based Peak and Trough Detection (Scholkmann et al. 2012)
  // with early-termination optimisation.
  //
  // For every sample i we count gamma[i] = number of consecutive scales s
  // (starting at s=1) for which signal[i] is strictly greater than
  // signal[i−s] AND signal[i+s].  Because we grow s from 1 upward, the
  // endpoint check is equivalent to a full-window maximum check, and the
  // first failure means no larger scale can pass either → early exit.
  double? peakHeartRate;
  List<int> peakTimestamps = const [];

  if (n >= 8) {
    final safeSF = effectiveSampleFreqHz.isFinite && effectiveSampleFreqHz > 0
        ? effectiveSampleFreqHz
        : (input.sampleFreq.isFinite && input.sampleFreq > 0
            ? input.sampleFreq
            : 50.0);

    // Limit peak detection to the most recent 8 seconds.
    final maxPeakSamples = min(n, (safeSF * 8).round());
    final peakStart = n - maxPeakSamples;
    final peakN = maxPeakSamples;
    final peakSignals = signals.sublist(peakStart);
    final peakTs = timestamps.sublist(peakStart);

    // Scale limits derived from physiological beat-interval range.
    final scaleMax = min(peakN ~/ 2,
        max(1, (safeSF * input.maxBeatIntervalSec / 2).round()));
    final scaleThreshold =
        max(1, (safeSF * input.minBeatIntervalSec / 2).round());

    // Build scalogram column sums (gamma) with early termination.
    final gamma = List<int>.filled(peakN, 0);
    for (var i = 1; i < peakN - 1; i++) {
      final maxS = min(scaleMax, min(i, peakN - 1 - i));
      for (var s = 1; s <= maxS; s++) {
        if (peakSignals[i] > peakSignals[i - s] && peakSignals[i] > peakSignals[i + s]) {
          gamma[i]++;
        } else {
          break; // early termination – larger scales cannot pass
        }
      }
    }

    // Collect candidate peaks: gamma must reach an adaptive threshold
    // (at least 40% of the strongest gamma) to suppress secondary maxima
    // like dicrotic notches and harmonics.
    final maxGamma = gamma.reduce(max);
    final adaptiveThreshold = max(scaleThreshold, (maxGamma * 0.4).round());
    final minDist = max(1, (safeSF * input.minBeatIntervalSec * 0.85).round());
    final peakIndices = <int>[];

    for (var i = 1; i < peakN - 1; i++) {
      if (gamma[i] < adaptiveThreshold) continue;
      if (gamma[i] < gamma[i - 1] || gamma[i] < gamma[i + 1]) continue;

      // Enforce refractory period – keep the more prominent peak.
      if (peakIndices.isNotEmpty && (i - peakIndices.last) < minDist) {
        if (gamma[i] > gamma[peakIndices.last]) {
          peakIndices[peakIndices.length - 1] = i;
        }
        continue;
      }
      peakIndices.add(i);
    }

    peakTimestamps =
        peakIndices.map((i) => peakTs[i]).toList(growable: false);

    // HR from peaks.
    if (peakTimestamps.length >= 2) {
      final intervals = <double>[];
      for (var i = 1; i < peakTimestamps.length; i++) {
        final sec = (peakTimestamps[i] - peakTimestamps[i - 1]).toDouble() /
            max(1.0, tps);
        if (sec >= input.minBeatIntervalSec &&
            sec <= input.maxBeatIntervalSec) {
          intervals.add(sec);
        }
      }
      if (intervals.isNotEmpty) {
        final hr = 60.0 / intervals.last;
        if (hr.isFinite && hr >= 30 && hr <= 240) peakHeartRate = hr;
      }
    }

    // ── Peak-amplitude-to-median ratio ────────────────────────────────────
    // Max peak amplitude / median peak amplitude over the 8 s window.
    peakCount = peakIndices.length;
    peakWindowSamples = peakN;
    if (peakIndices.length >= 2) {
      final peakAmps = peakIndices
          .map((idx) => peakSignals[idx])
          .toList()
        ..sort();
      final maxPeakAmp = peakAmps.last;
      final mid = peakAmps.length ~/ 2;
      final medianPeakAmp = peakAmps.length.isOdd
          ? peakAmps[mid]
          : (peakAmps[mid - 1] + peakAmps[mid]) / 2;

      if (medianPeakAmp.abs() > 1e-9) {
        peakToMedianRatio = maxPeakAmp / medianPeakAmp;
        reasons.write(', peakToMedian=${peakToMedianRatio.toStringAsFixed(2)} '
            '(maxPeak=${maxPeakAmp.toStringAsFixed(4)}, '
            'medianPeak=${medianPeakAmp.toStringAsFixed(4)})');
      } else {
        reasons.write(', peakToMedian=N/A (medianPeak~0)');
      }
    }
  }

  // ── Peak-count quality factor ────────────────────────────────────────────
  final peakScore = (peakTimestamps.length / 8.0).clamp(0.0, 1.0);
  qualityScore =
      ((0.78 * qualityScore) + (0.22 * peakScore)).clamp(0.0, 1.0);
  reasons.write(', peaks=${peakTimestamps.length} '
      'peakScore=${peakScore.toStringAsFixed(2)} '
      'afterPeak=${qualityScore.toStringAsFixed(2)}');

  // ── IBI computation ──────────────────────────────────────────────────────
  final ibiTicks = <double>[];
  for (var i = 1; i < peakTimestamps.length; i++) {
    final interval = (peakTimestamps[i] - peakTimestamps[i - 1]).toDouble();
    final sec = interval / tps;
    if (interval > 0 &&
        sec >= input.minBeatIntervalSec &&
        sec <= input.maxBeatIntervalSec) {
      ibiTicks.add(interval);
    }
  }

  // ── Rhythm-based quality refinement ──────────────────────────────────────
  if (ibiTicks.length >= 2) {
    final sorted = [...ibiTicks]..sort();
    final median = sorted[sorted.length ~/ 2];
    final low = median * 0.65;
    final high = median * 1.35;
    final robust =
        ibiTicks.where((v) => v >= low && v <= high).toList(growable: false);
    final robustIbi = robust.length >= 2 ? robust : ibiTicks;

    final meanIbi = robustIbi.reduce((a, b) => a + b) / robustIbi.length;
    if (meanIbi.isFinite && meanIbi > 0) {
      var sqSum = 0.0;
      for (final v in robustIbi) {
        final d = v - meanIbi;
        sqSum += d * d;
      }
      final ibiVariation = sqrt(sqSum / robustIbi.length) / meanIbi;
      if (ibiVariation.isFinite) {
        final rhythmScore = (1.0 - (ibiVariation / 0.55)).clamp(0.0, 1.0);
        qualityScore =
            ((0.78 * qualityScore) + (0.22 * rhythmScore)).clamp(0.0, 1.0);
        reasons.write(', ibiCV=${ibiVariation.toStringAsFixed(3)} '
            'rhythmScore=${rhythmScore.toStringAsFixed(2)} '
            'finalQ=${qualityScore.toStringAsFixed(2)}');
      }
    }
  }

  return _VitalsComputeResult(
    qualityScore: qualityScore,
    averageMotion: averageMotion,
    peakHeartRate: peakHeartRate,
    peakTimestamps: peakTimestamps,
    ibiTicks: ibiTicks,
    peakToMedianRatio: peakToMedianRatio,
    peakCount: peakCount,
    peakWindowSamples: peakWindowSamples,
    debugReason: reasons.toString(),
  );
}

enum PpgSignalQuality {
  unavailable,
  bad,
  fair,
  good,
}

class PpgOpticalSample {
  final int timestamp;
  final double red;
  final double ir;
  final double green;
  final double ambient;

  const PpgOpticalSample({
    required this.timestamp,
    required this.red,
    required this.ir,
    required this.green,
    required this.ambient,
  });
}

class PpgVitals {
  final double? heartRateBpm;
  final double? hrvRmssdMs;
  final double? hrvLfhfRatio;
  final PpgSignalQuality signalQuality;

  const PpgVitals({
    required this.heartRateBpm,
    required this.hrvRmssdMs,
    required this.hrvLfhfRatio,
    required this.signalQuality,
  });

  const PpgVitals.invalid({
    this.signalQuality = PpgSignalQuality.unavailable,
  })  : heartRateBpm = null,
        hrvRmssdMs = null,
        hrvLfhfRatio = null;
}

class PpgMotionSample {
  final int timestamp;
  final double x;
  final double y;
  final double z;

  const PpgMotionSample({
    required this.timestamp,
    required this.x,
    required this.y,
    required this.z,
  });

  double get magnitude => sqrt((x * x) + (y * y) + (z * z));
}

class PpgTemperatureSample {
  final int timestamp;
  final double celsius;

  const PpgTemperatureSample({
    required this.timestamp,
    required this.celsius,
  });
}

class PpgFilter {
  final Stream<PpgOpticalSample> inputStream;
  final Stream<PpgMotionSample>? motionStream;
  final Stream<PpgTemperatureSample>? opticalTemperatureStream;
  final double sampleFreq;
  final int timestampExponent;

  final StreamController<double?> _temperatureStreamController =
      StreamController.broadcast(); //追加

  final StreamController<List<int>> _peakTimestampsController =
      StreamController.broadcast();


  final HrvLfhfCalculator _hrvLfhfCalculator = HrvLfhfCalculator();

  double _hrEstimate = 75.0;
  double _hrCovariance = 1.0;
  double _hrProcessNoise = 0.02; //0.02
  double _hrMeasurementNoise = 5.0; //5.0

  double _hrvEstimateMs = 35.0;
  final double _hrvSmoothingAlpha = 0.18;

  StreamSubscription<PpgMotionSample>? _motionSubscription;
  StreamSubscription<PpgTemperatureSample>? _temperatureSubscription;
  Stream<_MotionAwareSample>? _processedStream;
  Stream<(int, double)>? _rawSignalStream;
  Stream<(int, double)>? _displaySignalStream;
  Stream<PpgVitals>? _vitalsStream;

  double? _latestOpticalTemperatureCelsius;
  int? _latestOpticalTemperatureTimestamp;

  static const double _reasonableInEarTemperatureCelsius = 0.0;
  static const double _maxTemperatureSampleAgeSec = 20.0;
  static const double _minBeatIntervalSec = 0.25;
  static const double _maxBeatIntervalSec = 2.0;

  PpgFilter({
    required this.inputStream,
    required this.sampleFreq,
    required this.timestampExponent,
    this.motionStream,
    this.opticalTemperatureStream,
  });

  void initialize() {
    // Eagerly build pipelines so filters/subscriptions are ready on app start.
    displaySignalStream;
    _sampleStream;
    _metricsStream;

    //debugPrint(
    //'opticalTemperatureStream is ${opticalTemperatureStream == null ? "null" : "not null"}');

    if (opticalTemperatureStream != null) {
      _temperatureSubscription = opticalTemperatureStream!.listen((sample) {
        _latestOpticalTemperatureCelsius = sample.celsius;
        _latestOpticalTemperatureTimestamp = sample.timestamp;
        _temperatureStreamController.add(sample.celsius);
        //debugPrint('Temperature sample added: ${sample.celsius}');
      });
    }

    debugPrint('Initialization...');
  }

  Stream<(int, double)> get displaySignalStream {
    if (_displaySignalStream != null) {
      return _displaySignalStream!;
    }
    _displaySignalStream = _sampleStream
        .map((sample) => (sample.timestamp, sample.signal))
        .asBroadcastStream();
    return _displaySignalStream!;
  }

  Stream<(int, double)> get rawSignalStream {
    if (_rawSignalStream != null) {
      return _rawSignalStream!;
    }
    _rawSignalStream = _sampleStream
        .map((sample) => (sample.timestamp, sample.rawGreen))
        .asBroadcastStream();
    return _rawSignalStream!;
  }

  Stream<double?> get heartRateStream =>
      _metricsStream.map((vitals) => vitals.heartRateBpm);

  Stream<double?> get hrvStream =>
      _metricsStream.map((vitals) => vitals.hrvRmssdMs);

  Stream<double?> get hrvLfhfStream =>
      _metricsStream.map((vitals) => vitals.hrvLfhfRatio);

  Stream<PpgSignalQuality> get signalQualityStream =>
      _metricsStream.map((vitals) => vitals.signalQuality).distinct();

  Stream<double?> get temperatureStream => _temperatureStreamController.stream;

  Stream<List<int>> get peakTimestampsStream =>
      _peakTimestampsController.stream;


  void dispose() {
    final motionSubscription = _motionSubscription;
    _motionSubscription = null;
    if (motionSubscription != null) {
      unawaited(motionSubscription.cancel());
    }

    final temperatureSubscription = _temperatureSubscription;
    _temperatureSubscription = null;
    if (temperatureSubscription != null) {
      unawaited(temperatureSubscription.cancel());
    }
    _temperatureStreamController.close();
    _peakTimestampsController.close();
  }

  Stream<_MotionAwareSample> get _sampleStream {
    if (_processedStream != null) {
      return _processedStream!;
    }
    _processedStream = _createProcessedStream().asBroadcastStream();
    return _processedStream!;
  }

  Stream<PpgVitals> get _metricsStream {
    if (_vitalsStream != null) {
      return _vitalsStream!;
    }
    _vitalsStream = _createVitalsStream().asBroadcastStream();
    return _vitalsStream!;
  }

  static int _pickStableDisplayChannel(PpgOpticalSample sample) {
    final candidates = [sample.green, sample.red, sample.ir];
    var bestChannel = 0;
    var bestEnergy = -1.0;
    for (var i = 0; i < candidates.length; i++) {
      final value = candidates[i];
      if (!value.isFinite) continue;
      final energy = value.abs();
      if (energy > bestEnergy && energy > 1e-9) {
        bestEnergy = energy;
        bestChannel = i;
      }
    }
    return bestChannel;
  }

  static double _readDisplayChannel(PpgOpticalSample sample, int channelIndex) {
    switch (channelIndex) {
      case 1:
        return sample.red;
      case 2:
        return sample.ir;
      case 0:
      default:
        return sample.green;
    }
  }

  Stream<_MotionAwareSample> _createProcessedStream() {
    final safeSampleFreq =
        sampleFreq.isFinite && sampleFreq > 0 ? sampleFreq : 50.0;
    final ambientCanceler = _AmbientLightCanceler();
    final motionSuppressor = _MotionNoiseSuppressor();
    final imuCanceler = _MultiReferenceMotionCanceler();
    final dcBlockFilter = HighPassFilter(
      cutoffFreq: 0.12,
      sampleFreq: safeSampleFreq,
    );
    final bandPassFilter = BandPassFilter(
      sampleFreq: safeSampleFreq,
      lowCut: 0.5,
      highCut: 8.0,
    );
    final normalizer = _BoundedSignalNormalizer();
    final displayDetrender = _DisplayBaselineDetrender(
      sampleFreqHz: safeSampleFreq,
      timeConstantSeconds: 3.2,
    );

    if (motionStream != null) {
      _motionSubscription = motionStream!.listen((event) {
        motionSuppressor.updateMotionMagnitude(event.magnitude);
        imuCanceler.updateMotion(event);
      });
    }
    return inputStream.map((sample) {
      // Always use green channel.
      final selectedOpticalSignal = sample.green;

      final ambientCanceled = ambientCanceler.filter(
        green: selectedOpticalSignal,
        ambient: sample.ambient,
      );
      final imuCleaned = imuCanceler.filter(
        ambientCanceled,
        motionLevel: motionSuppressor.motionLevel,
      );
      final motionSuppressed = motionSuppressor.filter(imuCleaned);
      final dcBlocked = dcBlockFilter.filter(motionSuppressed);
      final bandPassed = bandPassFilter.filter(dcBlocked);
      final bounded = normalizer.filter(
        bandPassed,
        motionLevel: motionSuppressor.motionLevel,
      );
      final displaySignal = displayDetrender.filter(bounded);

      return _MotionAwareSample(
        timestamp: sample.timestamp,
        rawGreen: selectedOpticalSignal,
        rawAmbient: sample.ambient,
        rawRed: sample.red,
        rawIr: sample.ir,
        signal: bandPassed,
        displaySignal: displaySignal,
        motionLevel: motionSuppressor.motionLevel,
      );
    });
  }

  double _kalmanUpdateHeartRate(double measurement) {
    if (!measurement.isFinite) {
      return _hrEstimate;
    }

    _hrCovariance += _hrProcessNoise;
    final gain = _hrCovariance / (_hrCovariance + _hrMeasurementNoise);
    _hrEstimate += gain * (measurement - _hrEstimate);
    _hrCovariance *= (1 - gain);
    return _hrEstimate;
  }

  double _smoothHrv(double measurementMs) {
    if (!measurementMs.isFinite || measurementMs <= 0) {
      return _hrvEstimateMs;
    }
    _hrvEstimateMs = (_hrvEstimateMs * (1.0 - _hrvSmoothingAlpha)) +
        (measurementMs * _hrvSmoothingAlpha);
    return _hrvEstimateMs;
  }

  List<double> _removeIbiOutliers(List<double> ibiTicks) {
    if (ibiTicks.length < 3) {
      return ibiTicks;
    }

    final sorted = [...ibiTicks]..sort();
    final median = sorted[sorted.length ~/ 2];
    final low = median * 0.65;
    final high = median * 1.35;
    final filtered = ibiTicks
        .where((ibi) => ibi >= low && ibi <= high)
        .toList(growable: false);
    return filtered.length >= 2 ? filtered : ibiTicks;
  }

  double? _computeRmssd(List<double> ibiTicks) {
    if (ibiTicks.length < 2) {
      return null;
    }

    var sumSquared = 0.0;
    var count = 0;
    for (var i = 1; i < ibiTicks.length; i++) {
      final delta = ibiTicks[i] - ibiTicks[i - 1];
      sumSquared += delta * delta;
      count += 1;
    }

    if (count == 0) {
      return null;
    }
    return sqrt(sumSquared / count);
  }

  PpgSignalQuality _classifyQuality(double score) {
    if (!score.isFinite || score <= 0) {
      return PpgSignalQuality.unavailable;
    }
    if (score < 0.30) {
      return PpgSignalQuality.bad;
    }
    if (score < 0.62) {
      return PpgSignalQuality.fair;
    }
    return PpgSignalQuality.good;
  }

  ({bool hasFreshTemperatureSample, bool inEarByTemperature})
      _estimateInEarByOpticalTemperature({
    required int latestTimestamp,
    required double ticksPerSecond,
  }) {
    if (opticalTemperatureStream == null) {
      return (hasFreshTemperatureSample: false, inEarByTemperature: true);
    }

    final latestTemperature = _latestOpticalTemperatureCelsius;
    final latestTemperatureTimestamp = _latestOpticalTemperatureTimestamp;
    if (latestTemperature == null || latestTemperatureTimestamp == null) {
      return (hasFreshTemperatureSample: false, inEarByTemperature: false);
    }

    final maxAgeTicks = _maxTemperatureSampleAgeSec * ticksPerSecond;
    if (latestTimestamp - latestTemperatureTimestamp > maxAgeTicks) {
      return (hasFreshTemperatureSample: false, inEarByTemperature: false);
    }

    return (
      hasFreshTemperatureSample: true,
      inEarByTemperature:
          latestTemperature >= _reasonableInEarTemperatureCelsius,
    );
  }

  Stream<PpgVitals> _createVitalsStream() async* {
    final ticksPerSecond = pow(10, -timestampExponent).toDouble();
    final ticksToMilliseconds = pow(10, timestampExponent + 3).toDouble();
    final windowDurationTicks = 60.0 * ticksPerSecond;
    final minimumWindowTicks = 4.0 * ticksPerSecond;
    final evaluationPeriodTicks = max(1.0, ticksPerSecond);
    final buffer = <_MotionAwareSample>[];
    var lastEvaluationTick = double.negativeInfinity;

    PpgSignalQuality? previousQuality;
    double? lastValidHeartRate;

    await for (final sample in _sampleStream) {
      buffer.add(sample);
      final cutoff = sample.timestamp - windowDurationTicks;
      while (buffer.isNotEmpty && buffer.first.timestamp < cutoff) {
        buffer.removeAt(0);
      }

      if ((sample.timestamp - lastEvaluationTick) < evaluationPeriodTicks) {
        continue;
      }
      lastEvaluationTick = sample.timestamp.toDouble();

      //debugPrint('rawRed: ${sample.rawRed}, rawIr: ${sample.rawIr}');
      /*if (sample.rawIr >= 9.6e6 || (sample.rawRed - sample.rawIr).abs() > 1e5) {
        debugPrint('PPG Quality: unavailable — rawIr=${sample.rawIr.toStringAsFixed(0)}, '
            '|rawRed-rawIr|=${(sample.rawRed - sample.rawIr).abs().toStringAsFixed(0)} '
            '(sensor saturated or no skin contact)');
        yield const PpgVitals.invalid(
            signalQuality: PpgSignalQuality.unavailable);
        continue;
      }*/

      if (buffer.length < 20 ||
          (buffer.last.timestamp - buffer.first.timestamp) <
              minimumWindowTicks) {
        debugPrint('PPG Quality: unavailable — buffer too small '
            '(${buffer.length} samples, '
            '${((buffer.last.timestamp - buffer.first.timestamp) / ticksPerSecond).toStringAsFixed(1)}s)');
        yield const PpgVitals.invalid(
          signalQuality: PpgSignalQuality.unavailable,
        );
        continue;
      }
      // Run heavy computation (quality scoring, peak detection, IBI)
      // in a background isolate to keep the UI thread responsive.
      final computeInput = _VitalsComputeInput(
        signals: buffer.map((s) => s.signal).toList(growable: false),
        motionLevels:
            buffer.map((s) => s.motionLevel).toList(growable: false),
        timestamps:
            buffer.map((s) => s.timestamp).toList(growable: false),
        latestTimestamp: sample.timestamp,
        ticksPerSecond: ticksPerSecond,
        sampleFreq: sampleFreq,
        minBeatIntervalSec: _minBeatIntervalSec,
        maxBeatIntervalSec: _maxBeatIntervalSec,
      );

      final result = await compute(_evaluateVitalsIsolated, computeInput);

      // Emit detected peak timestamps for chart overlays.
      _peakTimestampsController.add(result.peakTimestamps);

      var qualityScore = result.qualityScore;
      final recentMotion = result.averageMotion;
      final peakHeartRate = result.peakHeartRate;
      final ibiTicks = result.ibiTicks;

      // ── Peak-to-median & peak-count quality overrides ─────────────────
      final ptm = result.peakToMedianRatio;
      final expectedMinPeaks = (result.peakWindowSamples / sampleFreq) ~/ 2;
      if (ptm != null && ptm >= 15 || result.peakCount < expectedMinPeaks) {
        debugPrint('PPG Quality: unavailable — '
            'peakToMedian=${ptm?.toStringAsFixed(2) ?? "N/A"}, '
            'peaks=${result.peakCount} (min=$expectedMinPeaks) — '
            '${result.debugReason}');
        yield const PpgVitals.invalid(
          signalQuality: PpgSignalQuality.unavailable,
        );
        previousQuality = PpgSignalQuality.unavailable;
        continue;
      }
      if (ptm != null && ptm >= 5.0) {
        debugPrint('PPG Quality: bad — '
            'peakToMedian=${ptm.toStringAsFixed(2)} >= 10 — '
            '${result.debugReason}');
        yield const PpgVitals.invalid(
          signalQuality: PpgSignalQuality.bad,
        );
        previousQuality = PpgSignalQuality.bad;
        continue;
      }
      if (ptm != null && ptm >= 2.0) {
        debugPrint('PPG Quality: fair — '
            'peakToMedian=${ptm.toStringAsFixed(2)} >= 5 — '
            '${result.debugReason}');
        qualityScore = min(qualityScore, 0.50);
      }

      final inEarTemperature = _estimateInEarByOpticalTemperature(
        latestTimestamp: sample.timestamp,
        ticksPerSecond: ticksPerSecond,
      );
      if (opticalTemperatureStream != null) {
        if (!inEarTemperature.hasFreshTemperatureSample) {
          debugPrint('PPG Quality: unavailable — no fresh temperature sample');
          yield const PpgVitals.invalid(
            signalQuality: PpgSignalQuality.unavailable,
          );
          continue;
        }
        if (!inEarTemperature.inEarByTemperature) {
          debugPrint('PPG Quality: bad — temperature below threshold '
              '(not in ear)');
          yield const PpgVitals.invalid(
            signalQuality: PpgSignalQuality.bad,
          );
          continue;
        }
      }

      void adjustKalmanParameters(PpgSignalQuality quality) {
        switch (quality) {
          case PpgSignalQuality.good:
            //_hrProcessNoise = 0.10;
            _hrMeasurementNoise = 1.0;
            break;
          case PpgSignalQuality.fair:
            //_hrProcessNoise = 0.01;
            _hrMeasurementNoise = 5.0;
            break;
          case PpgSignalQuality.bad:
            //_hrProcessNoise = 0.005;
            //_hrMeasurementNoise = 20.0;
            break;
          case PpgSignalQuality.unavailable:
            //_hrProcessNoise = 0.001;
            //_hrMeasurementNoise = 10.0;
            break;
        }
        /*debugPrint('Kalman parameters updated: '
            '_hrProcessNoise=$_hrProcessNoise, '
            '_hrMeasurementNoise=$_hrMeasurementNoise');*/
      }

      final classifiedQuality = _classifyQuality(qualityScore);
      debugPrint('PPG Quality: ${classifiedQuality.name} '
          '(score=${qualityScore.toStringAsFixed(3)}, '
          'HR=${peakHeartRate?.toStringAsFixed(1) ?? "null"}) — '
          '${result.debugReason}');

      if (previousQuality != null) {
        if ((previousQuality == PpgSignalQuality.good ||
                previousQuality == PpgSignalQuality.fair) &&
            (classifiedQuality == PpgSignalQuality.bad ||
                classifiedQuality == PpgSignalQuality.unavailable)) {
          if (peakHeartRate != null && peakHeartRate.isFinite) {
            lastValidHeartRate = peakHeartRate;
            debugPrint(
                'Signal quality degraded: hold heart rate $lastValidHeartRate');
          }
        }

        if ((previousQuality == PpgSignalQuality.bad ||
                previousQuality == PpgSignalQuality.unavailable) &&
            (classifiedQuality == PpgSignalQuality.good ||
                classifiedQuality == PpgSignalQuality.fair)) {
          if (lastValidHeartRate != null && lastValidHeartRate.isFinite) {
            _hrEstimate = lastValidHeartRate;
            _hrCovariance = 1.0;
            debugPrint(
                'Signal quality improved: reset Kalman filter HR estimate to $lastValidHeartRate');
            // 保持した心拍数は使い切ったのでクリアしておく
            lastValidHeartRate = null;
          }
        }
      }

      if (classifiedQuality == PpgSignalQuality.bad ||
          classifiedQuality == PpgSignalQuality.unavailable) {
        yield PpgVitals.invalid(signalQuality: classifiedQuality);
        previousQuality = classifiedQuality;
        continue;
      }

      adjustKalmanParameters(classifiedQuality);

      if (peakHeartRate == null) {
        yield PpgVitals.invalid(
          signalQuality: classifiedQuality,
        );
        previousQuality = classifiedQuality;
        continue;
      }
      final smoothedHeartRate = _kalmanUpdateHeartRate(peakHeartRate);
      //final smoothedHeartRate = peakHeartRate;

      double? smoothedHrvMs;
      double? lfhfRatio;
      if (ibiTicks.length >= 2) {
        final robustIbiTicks = _removeIbiOutliers(ibiTicks);
        final rmssdTicks = _computeRmssd(robustIbiTicks);
        if (rmssdTicks != null && rmssdTicks.isFinite && rmssdTicks > 0) {
          final hrvMs = rmssdTicks * ticksToMilliseconds;
          if (hrvMs.isFinite && hrvMs >= 5 && hrvMs <= 300) {
            smoothedHrvMs = _smoothHrv(hrvMs);
          }
        }

        final ibiMsList =
            robustIbiTicks.map((e) => e * ticksToMilliseconds).toList();

        for (final ibiMs in ibiMsList) {
          _hrvLfhfCalculator.addIbi(ibiMs);
        }

        lfhfRatio = _hrvLfhfCalculator.compute()?.lfHfRatio;
      }

      yield PpgVitals(
        heartRateBpm: smoothedHeartRate,
        hrvRmssdMs: smoothedHrvMs,
        hrvLfhfRatio: lfhfRatio,
        signalQuality: classifiedQuality,
      );

      previousQuality = classifiedQuality;
    }
  }
}

class _AdaptiveOpticalChannelSelector {
  bool _isInitialized = false;
  double _meanGreen = 0;
  double _meanRed = 0;
  double _meanIr = 0;
  double _energyGreen = 0;
  double _energyRed = 0;
  double _energyIr = 0;

  double select(PpgOpticalSample sample) {
    if (!_isInitialized) {
      _isInitialized = true;
      _meanGreen = sample.green;
      _meanRed = sample.red;
      _meanIr = sample.ir;
    } else {
      _meanGreen = _ema(_meanGreen, sample.green, 0.02);
      _meanRed = _ema(_meanRed, sample.red, 0.02);
      _meanIr = _ema(_meanIr, sample.ir, 0.02);
    }

    _energyGreen = _ema(_energyGreen, (sample.green - _meanGreen).abs(), 0.08);
    _energyRed = _ema(_energyRed, (sample.red - _meanRed).abs(), 0.08);
    _energyIr = _ema(_energyIr, (sample.ir - _meanIr).abs(), 0.08);

    final strongestAltEnergy = max(_energyRed, _energyIr);
    final greenLikelyMissing = sample.green.abs() < 1e-6 &&
        (sample.red.abs() > 1e-3 || sample.ir.abs() > 1e-3);
    final greenWeakComparedToAlternatives =
        strongestAltEnergy > 1e-6 && _energyGreen < (strongestAltEnergy * 0.35);
    if (greenLikelyMissing || greenWeakComparedToAlternatives) {
      final preferRed = _energyRed >= _energyIr;
      final fallback = preferRed ? sample.red : sample.ir;
      if (fallback.isFinite) {
        return fallback;
      }
    }

    if (sample.green.isFinite) {
      return sample.green;
    }
    if (sample.red.isFinite && sample.ir.isFinite) {
      return sample.red.abs() >= sample.ir.abs() ? sample.red : sample.ir;
    }
    if (sample.red.isFinite) {
      return sample.red;
    }
    if (sample.ir.isFinite) {
      return sample.ir;
    }
    return 0;
  }

  double _ema(double state, double value, double alpha) {
    return (state * (1.0 - alpha)) + (value * alpha);
  }
}

class _MotionAwareSample {
  final int timestamp;
  final double rawGreen;
  final double rawAmbient;
  final double rawRed;
  final double rawIr;
  final double signal;
  final double displaySignal;
  final double motionLevel;

  const _MotionAwareSample({
    required this.timestamp,
    required this.rawGreen,
    required this.rawAmbient,
    required this.rawRed,
    required this.rawIr,
    required this.signal,
    required this.displaySignal,
    required this.motionLevel,
  });
}

class _DisplayBaselineDetrender {
  final double _alpha;
  bool _isInitialized = false;
  double _baseline = 0;
  double _lastOutput = 0;

  _DisplayBaselineDetrender({
    required double sampleFreqHz,
    double timeConstantSeconds = 3.0,
  }) : _alpha = _computeAlpha(
          sampleFreqHz: sampleFreqHz,
          timeConstantSeconds: timeConstantSeconds,
        );

  double filter(double value) {
    if (!_isInitialized) {
      _isInitialized = true;
      _baseline = value;
      _lastOutput = 0;
      return 0;
    }

    _baseline = _baseline + (_alpha * (value - _baseline));
    final detrended = value - _baseline;
    _lastOutput = (_lastOutput * 0.82) + (detrended * 0.18);
    return _lastOutput;
  }

  static double _computeAlpha({
    required double sampleFreqHz,
    required double timeConstantSeconds,
  }) {
    final safeSampleFreq =
        sampleFreqHz.isFinite && sampleFreqHz > 0 ? sampleFreqHz : 50.0;
    final safeTau = timeConstantSeconds.isFinite && timeConstantSeconds > 0
        ? timeConstantSeconds
        : 3.0;
    final alpha = 1 - exp(-1 / (safeTau * safeSampleFreq));
    return alpha.clamp(0.001, 0.2);
  }
}

class _AmbientLightCanceler {
  bool _isInitialized = false;
  double _meanGreen = 0;
  double _meanAmbient = 0;
  double _ambientVariance = 1.0;
  double _greenAmbientCovariance = 0.0;
  double _ambientGain = 0.65;

  double filter({
    required double green,
    required double ambient,
  }) {
    if (!_isInitialized) {
      _isInitialized = true;
      _meanGreen = green;
      _meanAmbient = ambient;
      return 0;
    }

    const meanAlpha = 0.02;
    const covarianceAlpha = 0.04;

    _meanGreen = (_meanGreen * (1.0 - meanAlpha)) + (green * meanAlpha);
    _meanAmbient = (_meanAmbient * (1.0 - meanAlpha)) + (ambient * meanAlpha);

    final centeredGreen = green - _meanGreen;
    final centeredAmbient = ambient - _meanAmbient;

    _ambientVariance = (_ambientVariance * (1.0 - covarianceAlpha)) +
        ((centeredAmbient * centeredAmbient) * covarianceAlpha);
    _greenAmbientCovariance =
        (_greenAmbientCovariance * (1.0 - covarianceAlpha)) +
            ((centeredGreen * centeredAmbient) * covarianceAlpha);

    if (_ambientVariance > 1e-6) {
      _ambientGain = (_greenAmbientCovariance / _ambientVariance).clamp(
        0.0,
        2.0,
      );
    }

    final cleaned = centeredGreen - (_ambientGain * centeredAmbient);
    return -cleaned;
  }
}

class _MultiReferenceMotionCanceler {
  final _PadasipStyleMultiInputNlmsCanceler _canceler =
      _PadasipStyleMultiInputNlmsCanceler(
    tapsPerAxis: 8,
  );

  bool _isInitialized = false;
  double _gravityX = 0;
  double _gravityY = 0;
  double _gravityZ = 0;
  double _dynamicX = 0;
  double _dynamicY = 0;
  double _dynamicZ = 0;
  double _referenceScaleX = 0.2;
  double _referenceScaleY = 0.2;
  double _referenceScaleZ = 0.2;

  void updateMotion(PpgMotionSample sample) {
    if (!_isInitialized) {
      _isInitialized = true;
      _gravityX = sample.x;
      _gravityY = sample.y;
      _gravityZ = sample.z;
      _dynamicX = 0;
      _dynamicY = 0;
      _dynamicZ = 0;
      _referenceScaleX = 0.2;
      _referenceScaleY = 0.2;
      _referenceScaleZ = 0.2;
      return;
    }

    const gravityAlpha = 0.04;
    const dynamicAlpha = 0.18;
    const scaleAlpha = 0.06;

    _gravityX = (_gravityX * (1.0 - gravityAlpha)) + (sample.x * gravityAlpha);
    _gravityY = (_gravityY * (1.0 - gravityAlpha)) + (sample.y * gravityAlpha);
    _gravityZ = (_gravityZ * (1.0 - gravityAlpha)) + (sample.z * gravityAlpha);

    final hpX = sample.x - _gravityX;
    final hpY = sample.y - _gravityY;
    final hpZ = sample.z - _gravityZ;
    _referenceScaleX =
        (_referenceScaleX * (1.0 - scaleAlpha)) + (hpX.abs() * scaleAlpha);
    _referenceScaleY =
        (_referenceScaleY * (1.0 - scaleAlpha)) + (hpY.abs() * scaleAlpha);
    _referenceScaleZ =
        (_referenceScaleZ * (1.0 - scaleAlpha)) + (hpZ.abs() * scaleAlpha);

    final normalizedHpX = hpX / max(0.08, _referenceScaleX);
    final normalizedHpY = hpY / max(0.08, _referenceScaleY);
    final normalizedHpZ = hpZ / max(0.08, _referenceScaleZ);
    _dynamicX =
        (_dynamicX * (1.0 - dynamicAlpha)) + (normalizedHpX * dynamicAlpha);
    _dynamicY =
        (_dynamicY * (1.0 - dynamicAlpha)) + (normalizedHpY * dynamicAlpha);
    _dynamicZ =
        (_dynamicZ * (1.0 - dynamicAlpha)) + (normalizedHpZ * dynamicAlpha);
  }

  double filter(
    double value, {
    required double motionLevel,
  }) {
    if (!_isInitialized) {
      return value;
    }
    return _canceler.filter(
      signal: value,
      referenceX: _dynamicX,
      referenceY: _dynamicY,
      referenceZ: _dynamicZ,
      motionLevel: motionLevel,
    );
  }
}

/// Multi-input normalized LMS adaptive canceller adapted from the update rule
/// used in the open-source `padasip` NLMS implementation (MIT):
/// https://github.com/matousc89/padasip
class _PadasipStyleMultiInputNlmsCanceler {
  static const double _baseMu = 0.08;
  static const double _maxMu = 1.0;
  static const double _epsilon = 1e-6;
  static const double _leakage = 0.00025;

  final int tapsPerAxis;
  late final List<double> _weights;
  late final List<double> _historyX;
  late final List<double> _historyY;
  late final List<double> _historyZ;
  late final List<double> _featureVector;

  bool _isInitialized = false;
  double _smoothedError = 0;

  _PadasipStyleMultiInputNlmsCanceler({
    required this.tapsPerAxis,
  }) {
    final length = max(3, tapsPerAxis * 3);
    _weights = List<double>.filled(length, 0, growable: false);
    _historyX = List<double>.filled(tapsPerAxis, 0, growable: false);
    _historyY = List<double>.filled(tapsPerAxis, 0, growable: false);
    _historyZ = List<double>.filled(tapsPerAxis, 0, growable: false);
    _featureVector = List<double>.filled(length, 0, growable: false);
  }

  double filter({
    required double signal,
    required double referenceX,
    required double referenceY,
    required double referenceZ,
    required double motionLevel,
  }) {
    if (!signal.isFinite ||
        !referenceX.isFinite ||
        !referenceY.isFinite ||
        !referenceZ.isFinite) {
      return signal;
    }
    if (!_isInitialized) {
      _isInitialized = true;
      _smoothedError = signal;
    }

    _push(_historyX, referenceX);
    _push(_historyY, referenceY);
    _push(_historyZ, referenceZ);
    _composeFeatureVector();

    final predictedNoise = _dot(_weights, _featureVector);
    final error = signal - predictedNoise;
    final norm = _epsilon + _dot(_featureVector, _featureVector);

    final motionScale = (motionLevel / 1.6).clamp(0.0, 1.0);
    final mu = _baseMu + ((_maxMu - _baseMu) * motionScale);
    final step = (mu * error) / norm;

    for (var i = 0; i < _weights.length; i++) {
      final updatedWeight =
          ((1.0 - _leakage) * _weights[i]) + (step * _featureVector[i]);
      _weights[i] = updatedWeight.clamp(-4.0, 4.0);
    }

    final smoothAlpha = motionLevel > 1.0 ? 0.22 : 0.11;
    _smoothedError =
        (_smoothedError * (1.0 - smoothAlpha)) + (error * smoothAlpha);
    return _smoothedError;
  }

  void _push(List<double> history, double sample) {
    for (var i = history.length - 1; i > 0; i--) {
      history[i] = history[i - 1];
    }
    history[0] = sample;
  }

  void _composeFeatureVector() {
    var index = 0;
    for (var i = 0; i < tapsPerAxis; i++) {
      _featureVector[index++] = _historyX[i];
    }
    for (var i = 0; i < tapsPerAxis; i++) {
      _featureVector[index++] = _historyY[i];
    }
    for (var i = 0; i < tapsPerAxis; i++) {
      _featureVector[index++] = _historyZ[i];
    }
  }

  double _dot(List<double> a, List<double> b) {
    var sum = 0.0;
    for (var i = 0; i < a.length; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }
}

class _MotionNoiseSuppressor {
  static const int _windowSize = 25;
  static const double _baseOutlierSigma = 3.0;
  static const double _baseStepScale = 5.5;
  static const double _baseAlpha = 0.26;

  final ListQueue<double> _history = ListQueue<double>();

  bool _isInitialized = false;
  double _lastOutput = 0;
  double _gravityMagnitude = 9.81;
  double _motionLevel = 0;

  double get motionLevel => _motionLevel;

  void updateMotionMagnitude(double magnitude) {
    if (!_isInitialized) {
      _gravityMagnitude = magnitude;
      _motionLevel = 0;
      return;
    }

    _gravityMagnitude = (_gravityMagnitude * 0.96) + (magnitude * 0.04);
    final dynamicMagnitude = (magnitude - _gravityMagnitude).abs();
    final dynamicScale = max(0.08, _gravityMagnitude.abs() * 0.02);
    final normalizedDynamicMagnitude = dynamicMagnitude / dynamicScale;
    _motionLevel =
        ((_motionLevel * 0.85) + (normalizedDynamicMagnitude * 0.15)).clamp(
      0.0,
      8.0,
    );
  }

  double filter(double rawValue) {
    if (!_isInitialized) {
      _isInitialized = true;
      _lastOutput = rawValue;
      _history
        ..clear()
        ..addAll(List<double>.filled(_windowSize, rawValue));
      return rawValue;
    }

    if (_history.length >= _windowSize) {
      _history.removeFirst();
    }
    _history.add(rawValue);

    final median = _medianOf(_history);
    final mad = _medianOf(_history.map((value) => (value - median).abs()));
    final sigma = max(1e-3, mad * 1.4826);

    final motionFactor = 1.0 + min(_motionLevel / 0.85, 2.8);
    final outlierSigma = _baseOutlierSigma / motionFactor;
    final minBound = median - (sigma * outlierSigma);
    final maxBound = median + (sigma * outlierSigma);
    final clipped = rawValue.clamp(minBound, maxBound).toDouble();

    final stepLimit = max(1e-3, (_baseStepScale * sigma) / motionFactor);
    final stepped = _lastOutput +
        (clipped - _lastOutput).clamp(-stepLimit, stepLimit).toDouble();

    final alpha = (_baseAlpha / motionFactor).clamp(0.07, _baseAlpha);
    final smoothed = _lastOutput + (alpha * (stepped - _lastOutput));
    _lastOutput = smoothed;
    return smoothed;
  }

  double _medianOf(Iterable<double> values) {
    final sorted = values.toList(growable: false)..sort();
    if (sorted.isEmpty) {
      return 0;
    }
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) {
      return sorted[middle];
    }
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }
}

class _BoundedSignalNormalizer {
  bool _isInitialized = false;
  double _center = 0;
  double _envelope = 0.25;
  double _lastOutput = 0;

  double filter(
    double value, {
    required double motionLevel,
  }) {
    if (!_isInitialized) {
      _isInitialized = true;
      _center = value;
      _envelope = max(0.18, value.abs());
      _lastOutput = 0;
      return 0;
    }

    const centerAlpha = 0.01;
    const envelopeAlpha = 0.02;

    _center = (_center * (1.0 - centerAlpha)) + (value * centerAlpha);
    final centered = value - _center;
    _envelope =
        (_envelope * (1.0 - envelopeAlpha)) + (centered.abs() * envelopeAlpha);

    final normalized = centered / max(0.12, _envelope);
    final maxAbs = motionLevel > 1.2 ? 1.15 : 1.45;
    final clipped = normalized.clamp(-maxAbs, maxAbs).toDouble();

    final alpha = motionLevel > 1.2 ? 0.12 : 0.22;
    final smoothed = _lastOutput + (alpha * (clipped - _lastOutput));
    _lastOutput = smoothed;
    return smoothed;
  }
}
