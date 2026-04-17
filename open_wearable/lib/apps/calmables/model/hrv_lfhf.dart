import 'dart:math';

/// LF/HF比算出クラス
class HrvLfhfCalculator {
  final List<double> _ibiListMs = [];

  /// 1拍分の心拍間隔(msec)を追加
  /// 1分(60000ms)を超える古いデータは削除
  void addIbi(double ibiMs) {
    _ibiListMs.add(ibiMs);
    _trimToOneMinute();
  }

  void _trimToOneMinute() {
    double totalMs = _ibiListMs.fold(0, (a, b) => a + b);
    while (totalMs > 60000 && _ibiListMs.isNotEmpty) {
      totalMs -= _ibiListMs.removeAt(0);
    }
  }

  /// LF/HF比を計算。データ不足時はnullを返す
  double? computeLfhfRatio() {
    if (_ibiListMs.length < 30) return null; // 30拍未満は不十分

    // 秒単位に変換
    final ibiSec = _ibiListMs.map((e) => e / 1000.0).toList();

    // 3次スプライン補間し4Hzに等間隔化
    final resampled = _resampleWithCubicSpline(ibiSec, fsTarget: 4.0);
    if (resampled.isEmpty) return null;

    // 線形トレンド除去
    final detrended = _removeLinearTrend(resampled);

    // ハミング窓適用
    final windowed = _applyHammingWindow(detrended);

    // 256点FFT -> パワースペクトル密度算出
    final psd = _computePowerSpectralDensity(windowed, fs: 4.0);

    // LF(0.04-0.15Hz)とHF(0.15-0.40Hz)のパワー積分
    final lfPower = _bandPower(psd, fs: 4.0, fLow: 0.04, fHigh: 0.15);
    final hfPower = _bandPower(psd, fs: 4.0, fLow: 0.15, fHigh: 0.40);
    if (hfPower == 0) return null;

    return lfPower / hfPower;
  }

  // functions below are private helpers for the LF/HF calculation

  List<double> _resampleWithCubicSpline(List<double> ibiSec,
      {required double fsTarget}) {
    if (ibiSec.length < 4) return [];

    final timePoints = <double>[];
    double cumSum = 0;
    for (final v in ibiSec) {
      cumSum += v;
      timePoints.add(cumSum);
    }

    // Build target time axis at fsTarget Hz directly.
    final dtTarget = 1.0 / fsTarget;
    final targetTimes = <double>[];
    for (double t = timePoints.first; t <= timePoints.last; t += dtTarget) {
      targetTimes.add(t);
    }
    if (targetTimes.isEmpty) return [];

    // Natural cubic spline interpolation.
    return _cubicSplineInterpolate(timePoints, ibiSec, targetTimes);
  }

  /// Natural cubic spline interpolation.
  List<double> _cubicSplineInterpolate(
      List<double> x, List<double> y, List<double> xi) {
    final n = x.length;
    if (n < 2) return xi.map((_) => y.isEmpty ? 0.0 : y.first).toList();
    if (n == 2) {
      // Fall back to linear for 2 points.
      final slope = (y[1] - y[0]) / (x[1] - x[0]);
      return xi.map((t) => y[0] + slope * (t - x[0])).toList();
    }

    // h[i] = x[i+1] - x[i]
    final h = List<double>.generate(n - 1, (i) => x[i + 1] - x[i]);

    // Solve tridiagonal system for second derivatives (natural spline: s[0]=s[n-1]=0).
    final s = List<double>.filled(n, 0);
    final alpha = List<double>.filled(n, 0);
    for (var i = 1; i < n - 1; i++) {
      alpha[i] = 3.0 / h[i] * (y[i + 1] - y[i]) -
          3.0 / h[i - 1] * (y[i] - y[i - 1]);
    }

    final l = List<double>.filled(n, 1);
    final mu = List<double>.filled(n, 0);
    final z = List<double>.filled(n, 0);

    for (var i = 1; i < n - 1; i++) {
      l[i] = 2.0 * (x[i + 1] - x[i - 1]) - h[i - 1] * mu[i - 1];
      mu[i] = h[i] / l[i];
      z[i] = (alpha[i] - h[i - 1] * z[i - 1]) / l[i];
    }

    // Back-substitute.
    for (var j = n - 2; j >= 0; j--) {
      s[j] = z[j] - mu[j] * s[j + 1];
    }

    // Precompute polynomial coefficients for each segment.
    final b = List<double>.filled(n - 1, 0);
    final c = List<double>.filled(n - 1, 0);
    final d = List<double>.filled(n - 1, 0);
    for (var i = 0; i < n - 1; i++) {
      b[i] = (y[i + 1] - y[i]) / h[i] - h[i] * (s[i + 1] + 2.0 * s[i]) / 3.0;
      c[i] = s[i];
      d[i] = (s[i + 1] - s[i]) / (3.0 * h[i]);
    }

    // Evaluate spline at each target point.
    final result = <double>[];
    var seg = 0;
    for (final t in xi) {
      // Advance segment index.
      while (seg < n - 2 && t > x[seg + 1]) seg++;
      final dx = t - x[seg];
      result.add(y[seg] + b[seg] * dx + c[seg] * dx * dx + d[seg] * dx * dx * dx);
    }
    return result;
  }

  List<double> _removeLinearTrend(List<double> data) {
    final n = data.length;
    if (n < 2) return data;
    final x = List<double>.generate(n, (i) => i.toDouble());
    final meanX = (n - 1) / 2.0;
    final meanY = data.reduce((a, b) => a + b) / n;
    double num = 0, den = 0;
    for (int i = 0; i < n; i++) {
      num += (x[i] - meanX) * (data[i] - meanY);
      den += (x[i] - meanX) * (x[i] - meanX);
    }
    final slope = num / den;
    final intercept = meanY - slope * meanX;
    return List<double>.generate(n, (i) => data[i] - (slope * i + intercept));
  }

  List<double> _applyHammingWindow(List<double> data) {
    final n = data.length;
    return List<double>.generate(n, (i) {
      final w = 0.54 - 0.46 * cos(2 * pi * i / (n - 1));
      return data[i] * w;
    });
  }

  List<double> _computePowerSpectralDensity(List<double> data,
      {required double fs}) {
    final n = 256;
    final signal = List<double>.filled(n, 0);
    for (int i = 0; i < n && i < data.length; i++) {
      signal[i] = data[i];
    }
    final fftResult = _fft(signal);
    final psd = List<double>.filled(n ~/ 2 + 1, 0);
    for (int k = 0; k <= n ~/ 2; k++) {
      final re = fftResult[2 * k];
      final im = fftResult[2 * k + 1];
      psd[k] = (re * re + im * im) / (fs * n);
    }
    return psd;
  }

  List<double> _fft(List<double> input) {
    final n = input.length;
    if (n == 0 || (n & (n - 1)) != 0) {
      throw Exception('FFT length must be power of two');
    }
    List<double> buffer = List.filled(n * 2, 0);
    for (int i = 0; i < n; i++) {
      buffer[2 * i] = input[i];
      buffer[2 * i + 1] = 0;
    }
    _fftRecursive(buffer, n);
    return buffer;
  }

  void _fftRecursive(List<double> buffer, int n) {
    if (n <= 1) return;
    final half = n ~/ 2;
    final even = List<double>.filled(half * 2, 0);
    final odd = List<double>.filled(half * 2, 0);
    for (int i = 0; i < half; i++) {
      even[2 * i] = buffer[4 * i];
      even[2 * i + 1] = buffer[4 * i + 1];
      odd[2 * i] = buffer[4 * i + 2];
      odd[2 * i + 1] = buffer[4 * i + 3];
    }
    _fftRecursive(even, half);
    _fftRecursive(odd, half);
    for (int k = 0; k < half; k++) {
      final angle = -2 * pi * k / n;
      final cosVal = cos(angle);
      final sinVal = sin(angle);
      final oddRe = odd[2 * k];
      final oddIm = odd[2 * k + 1];
      final tRe = cosVal * oddRe - sinVal * oddIm;
      final tIm = cosVal * oddIm + sinVal * oddRe;
      buffer[2 * k] = even[2 * k] + tRe;
      buffer[2 * k + 1] = even[2 * k + 1] + tIm;
      buffer[2 * (k + half)] = even[2 * k] - tRe;
      buffer[2 * (k + half) + 1] = even[2 * k + 1] - tIm;
    }
  }

  double _bandPower(List<double> psd,
      {required double fs, required double fLow, required double fHigh}) {
    final n = (psd.length - 1) * 2;
    final df = fs / n;
    final startIndex = (fLow / df).ceil();
    final endIndex = (fHigh / df).floor();
    if (startIndex >= psd.length || endIndex < 0 || startIndex > endIndex)
      return 0;
    double power = 0;
    for (int i = startIndex; i <= endIndex && i < psd.length; i++) {
      power += psd[i];
    }
    return power;
  }
}
