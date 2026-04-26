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

    // 3次スプライン補間し1000Hz等間隔化、4Hzにダウンサンプリング
    final resampled = _resampleWithSpline(ibiSec, fsTarget: 4.0);
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

  List<double> _resampleWithSpline(List<double> ibiSec,
      {required double fsTarget}) {
    if (ibiSec.length < 4) return [];

    final timePoints = <double>[];
    double cumSum = 0;
    for (final v in ibiSec) {
      cumSum += v;
      timePoints.add(cumSum);
    }

    // 1000Hzの高分解能時間軸
    final fsHigh = 1000.0;
    final dtHigh = 1.0 / fsHigh;
    final highTimes = <double>[];
    for (double t = timePoints.first; t <= timePoints.last; t += dtHigh) {
      highTimes.add(t);
    }

    // 3次スプライン補間 → ここでは線形補間で代用
    final splineValues = _linearInterpolate(timePoints, ibiSec, highTimes);

    // 4Hzにダウンサンプリング
    final dtTarget = 1.0 / fsTarget;
    final targetTimes = <double>[];
    for (double t = timePoints.first; t <= timePoints.last; t += dtTarget) {
      targetTimes.add(t);
    }
    return _linearInterpolate(highTimes, splineValues, targetTimes);
  }

  List<double> _linearInterpolate(
      List<double> x, List<double> y, List<double> xi) {
    final result = <double>[];
    int j = 0;
    for (final t in xi) {
      while (j < x.length - 2 && t > x[j + 1]) j++;
      final x0 = x[j];
      final x1 = x[j + 1];
      final y0 = y[j];
      final y1 = y[j + 1];
      final ratio = (t - x0) / (x1 - x0);
      result.add(y0 + ratio * (y1 - y0));
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
      //final im = fftResult[2 * k + 1];
      psd[k] = (re * re) / (fs * n);
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
