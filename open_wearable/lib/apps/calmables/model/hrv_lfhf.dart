import 'dart:math';

class HrvFrequencyMetrics {
  final double lfPower;
  final double hfPower;
  final double lfHfRatio;
  final double? totalPower;
  final int usedIbiCount;
  final int resampledCount;

  const HrvFrequencyMetrics({
    required this.lfPower,
    required this.hfPower,
    required this.lfHfRatio,
    required this.totalPower,
    required this.usedIbiCount,
    required this.resampledCount,
  });

  @override
  String toString() {
    return 'HrvFrequencyMetrics('
        'lf=$lfPower, hf=$hfPower, lf/hf=$lfHfRatio, '
        'total=$totalPower, ibiCount=$usedIbiCount, resampled=$resampledCount'
        ')';
  }
}

class HrvLfhfCalculator {
  HrvLfhfCalculator({
    this.bufferDurationMs = 5 * 60 * 1000.0,
    this.fsResample = 4.0,
    this.minIbiMs = 300.0,
    this.maxIbiMs = 2000.0,
    this.enableArtifactFilter = true,
  });

  final double bufferDurationMs;
  final double fsResample;
  final double minIbiMs;
  final double maxIbiMs;
  final bool enableArtifactFilter;

  final List<double> _ibiListMs = [];

  void addIbi(double ibiMs) {
    if (!ibiMs.isFinite) return;
    _ibiListMs.add(ibiMs);
    _trimToBuffer();
  }

  void clear() {
    _ibiListMs.clear();
  }

  void _trimToBuffer() {
    double totalMs = _ibiListMs.fold(0.0, (a, b) => a + b);
    while (_ibiListMs.isNotEmpty && totalMs > bufferDurationMs) {
      totalMs -= _ibiListMs.removeAt(0);
    }
  }

  HrvFrequencyMetrics? compute() {
    if (_ibiListMs.length < 60) return null;

    final cleanedIbiMs = _prepareIbis(_ibiListMs);
    if (cleanedIbiMs.length < 40) return null;

    final ibiSec = cleanedIbiMs.map((e) => e / 1000.0).toList();

    final tachogram = _buildResampledTachogram(
      ibiSec,
      fsTarget: fsResample,
    );
    if (tachogram.length < 128) return null;

    final detrended = _removeLinearTrend(tachogram);

    final psd = _welchPsd(
      detrended,
      fs: fsResample,
      segmentLength: 256,
      overlap: 0.5,
    );
    if (psd == null) return null;

    final lf = _bandPower(
      psd.psd,
      df: psd.df,
      fLow: 0.04,
      fHigh: 0.15,
    );
    final hf = _bandPower(
      psd.psd,
      df: psd.df,
      fLow: 0.15,
      fHigh: 0.40,
    );
    final total = _bandPower(
      psd.psd,
      df: psd.df,
      fLow: 0.04,
      fHigh: 0.40,
    );

    if (!lf.isFinite || !hf.isFinite || hf <= 0.0) return null;

    return HrvFrequencyMetrics(
      lfPower: lf,
      hfPower: hf,
      lfHfRatio: lf / hf,
      totalPower: total.isFinite ? total : null,
      usedIbiCount: cleanedIbiMs.length,
      resampledCount: detrended.length,
    );
  }

  List<double> _prepareIbis(List<double> raw) {
    final bounded = raw
        .where((v) => v.isFinite && v >= minIbiMs && v <= maxIbiMs)
        .toList(growable: false);

    if (!enableArtifactFilter || bounded.length < 5) {
      return bounded;
    }

    final result = <double>[];
    for (var i = 0; i < bounded.length; i++) {
      final v = bounded[i];

      final start = max(0, i - 2);
      final end = min(bounded.length - 1, i + 2);
      final local = bounded.sublist(start, end + 1)..sort();
      final med = _median(local);

      if (med <= 0) continue;

      final relErr = (v - med).abs() / med;

      // Einfacher Artefaktfilter:
      // behalte Intervalle, die nicht zu stark vom lokalen Median abweichen.
      if (relErr <= 0.20) {
        result.add(v);
      }
    }
    return result;
  }

  List<double> _buildResampledTachogram(
    List<double> ibiSec, {
    required double fsTarget,
  }) {
    if (ibiSec.length < 4) return const [];

    // Intervallmitten als Zeitachse.
    final timePoints = <double>[];
    double t = 0.0;
    for (final ibi in ibiSec) {
      final mid = t + ibi / 2.0;
      timePoints.add(mid);
      t += ibi;
    }

    if (timePoints.length != ibiSec.length) return const [];
    if (t <= 0) return const [];

    final dt = 1.0 / fsTarget;
    final startT = timePoints.first;
    final endT = timePoints.last;

    if (endT <= startT) return const [];

    final targetTimes = <double>[];
    for (double tt = startT; tt <= endT; tt += dt) {
      targetTimes.add(tt);
    }
    if (targetTimes.length < 4) return const [];

    return _cubicSplineInterpolate(timePoints, ibiSec, targetTimes);
  }

  List<double> _cubicSplineInterpolate(
    List<double> x,
    List<double> y,
    List<double> xi,
  ) {
    final n = x.length;
    if (n == 0) return const [];
    if (n == 1) return xi.map((_) => y.first).toList(growable: false);
    if (n == 2) {
      final dx = x[1] - x[0];
      if (dx == 0) return xi.map((_) => y.first).toList(growable: false);
      final m = (y[1] - y[0]) / dx;
      return xi.map((t) => y[0] + m * (t - x[0])).toList(growable: false);
    }

    final h = List<double>.generate(n - 1, (i) => x[i + 1] - x[i]);
    for (final v in h) {
      if (v <= 0) return const [];
    }

    final alpha = List<double>.filled(n, 0.0);
    for (var i = 1; i < n - 1; i++) {
      alpha[i] = 3.0 * (y[i + 1] - y[i]) / h[i] -
          3.0 * (y[i] - y[i - 1]) / h[i - 1];
    }

    final l = List<double>.filled(n, 0.0);
    final mu = List<double>.filled(n, 0.0);
    final z = List<double>.filled(n, 0.0);
    final c = List<double>.filled(n, 0.0);
    final b = List<double>.filled(n - 1, 0.0);
    final d = List<double>.filled(n - 1, 0.0);

    l[0] = 1.0;
    mu[0] = 0.0;
    z[0] = 0.0;

    for (var i = 1; i < n - 1; i++) {
      l[i] = 2.0 * (x[i + 1] - x[i - 1]) - h[i - 1] * mu[i - 1];
      if (l[i] == 0.0) return const [];
      mu[i] = h[i] / l[i];
      z[i] = (alpha[i] - h[i - 1] * z[i - 1]) / l[i];
    }

    l[n - 1] = 1.0;
    z[n - 1] = 0.0;
    c[n - 1] = 0.0;

    for (var j = n - 2; j >= 0; j--) {
      c[j] = z[j] - mu[j] * c[j + 1];
      b[j] = (y[j + 1] - y[j]) / h[j] - h[j] * (c[j + 1] + 2.0 * c[j]) / 3.0;
      d[j] = (c[j + 1] - c[j]) / (3.0 * h[j]);
    }

    final out = <double>[];
    var seg = 0;
    for (final t in xi) {
      while (seg < n - 2 && t > x[seg + 1]) {
        seg++;
      }
      final dx = t - x[seg];
      out.add(y[seg] + b[seg] * dx + c[seg] * dx * dx + d[seg] * dx * dx * dx);
    }
    return out;
  }

  List<double> _removeLinearTrend(List<double> data) {
    final n = data.length;
    if (n < 2) return data;

    final meanX = (n - 1) / 2.0;
    final meanY = data.reduce((a, b) => a + b) / n;

    double num = 0.0;
    double den = 0.0;
    for (var i = 0; i < n; i++) {
      final dx = i - meanX;
      num += dx * (data[i] - meanY);
      den += dx * dx;
    }

    if (den == 0.0) return data;
    final slope = num / den;
    final intercept = meanY - slope * meanX;

    return List<double>.generate(
      n,
      (i) => data[i] - (slope * i + intercept),
      growable: false,
    );
  }

  _WelchResult? _welchPsd(
    List<double> data, {
    required double fs,
    required int segmentLength,
    required double overlap,
  }) {
    if (data.length < 32) return null;

    int nperseg = segmentLength;
    if (data.length < nperseg) {
      nperseg = _largestPowerOfTwoAtMost(data.length);
    }
    if (nperseg < 32) return null;

    final step = max(1, (nperseg * (1.0 - overlap)).round());
    if (step <= 0) return null;

    final window = _hammingWindow(nperseg);
    final windowPower = window.fold(0.0, (a, b) => a + b * b);
    if (windowPower <= 0.0) return null;

    final halfBins = nperseg ~/ 2 + 1;
    final avgPsd = List<double>.filled(halfBins, 0.0);

    var segments = 0;
    for (int start = 0; start + nperseg <= data.length; start += step) {
      final seg = data.sublist(start, start + nperseg);
      final mean = seg.reduce((a, b) => a + b) / seg.length;

      final x = List<double>.filled(nperseg, 0.0);
      for (var i = 0; i < nperseg; i++) {
        x[i] = (seg[i] - mean) * window[i];
      }

      final fft = _fftReal(x);

      for (var k = 0; k < halfBins; k++) {
        final re = fft[2 * k];
        final im = fft[2 * k + 1];
        double p = (re * re + im * im) / (fs * windowPower);

        // One-sided PSD correction except DC and Nyquist.
        if (k != 0 && !(nperseg.isEven && k == nperseg ~/ 2)) {
          p *= 2.0;
        }

        avgPsd[k] += p;
      }
      segments++;
    }

    if (segments == 0) return null;

    for (var i = 0; i < avgPsd.length; i++) {
      avgPsd[i] /= segments;
    }

    final df = fs / nperseg;
    return _WelchResult(psd: avgPsd, df: df);
  }

  List<double> _hammingWindow(int n) {
    if (n <= 1) return List<double>.filled(n, 1.0);
    return List<double>.generate(
      n,
      (i) => 0.54 - 0.46 * cos(2 * pi * i / (n - 1)),
      growable: false,
    );
  }

  double _bandPower(
    List<double> psd, {
    required double df,
    required double fLow,
    required double fHigh,
  }) {
    if (psd.isEmpty || df <= 0.0 || fHigh <= fLow) return 0.0;

    final startIndex = max(0, (fLow / df).ceil());
    final endIndex = min(psd.length - 1, (fHigh / df).floor());
    if (startIndex > endIndex) return 0.0;

    double power = 0.0;
    for (var i = startIndex; i <= endIndex; i++) {
      power += psd[i] * df;
    }
    return power;
  }

  double _median(List<double> values) {
    if (values.isEmpty) return 0.0;
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  int _largestPowerOfTwoAtMost(int n) {
    var p = 1;
    while ((p << 1) <= n) {
      p <<= 1;
    }
    return p;
  }

  List<double> _fftReal(List<double> input) {
    final n = input.length;
    if (n == 0 || (n & (n - 1)) != 0) {
      throw ArgumentError('FFT length must be a power of two');
    }

    final buffer = List<double>.filled(n * 2, 0.0);
    for (var i = 0; i < n; i++) {
      buffer[2 * i] = input[i];
      buffer[2 * i + 1] = 0.0;
    }

    _fftRecursive(buffer, n);
    return buffer;
  }

  void _fftRecursive(List<double> buffer, int n) {
    if (n <= 1) return;

    final half = n ~/ 2;
    final even = List<double>.filled(half * 2, 0.0);
    final odd = List<double>.filled(half * 2, 0.0);

    for (var i = 0; i < half; i++) {
      even[2 * i] = buffer[4 * i];
      even[2 * i + 1] = buffer[4 * i + 1];
      odd[2 * i] = buffer[4 * i + 2];
      odd[2 * i + 1] = buffer[4 * i + 3];
    }

    _fftRecursive(even, half);
    _fftRecursive(odd, half);

    for (var k = 0; k < half; k++) {
      final angle = -2 * pi * k / n;
      final c = cos(angle);
      final s = sin(angle);

      final oddRe = odd[2 * k];
      final oddIm = odd[2 * k + 1];

      final tRe = c * oddRe - s * oddIm;
      final tIm = c * oddIm + s * oddRe;

      buffer[2 * k] = even[2 * k] + tRe;
      buffer[2 * k + 1] = even[2 * k + 1] + tIm;
      buffer[2 * (k + half)] = even[2 * k] - tRe;
      buffer[2 * (k + half) + 1] = even[2 * k + 1] - tIm;
    }
  }
}

class _WelchResult {
  final List<double> psd;
  final double df;

  const _WelchResult({
    required this.psd,
    required this.df,
  });
}