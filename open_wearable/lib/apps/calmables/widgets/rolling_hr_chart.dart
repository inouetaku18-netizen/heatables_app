import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'package:flutter/material.dart';

/// A rolling chart that overlays two heart-rate series (raw + smoothed)
/// over a configurable time window (default 60 s).
class RollingHrChart extends StatefulWidget {
  final Stream<(int, double)> rawHrStream;
  final Stream<(int, double)> smoothedHrStream;
  final Stream<int>? bleGapStream;
  final int timestampExponent;
  final int timeWindow;

  const RollingHrChart({
    super.key,
    required this.rawHrStream,
    required this.smoothedHrStream,
    this.bleGapStream,
    required this.timestampExponent,
    this.timeWindow = 60,
  });

  @override
  State<RollingHrChart> createState() => _RollingHrChartState();
}

class _RollingHrChartState extends State<RollingHrChart> {
  final Queue<_Pt> _rawData = Queue();
  final Queue<_Pt> _smoothedData = Queue();
  final Queue<int> _gapTimestamps = Queue();
  StreamSubscription? _rawSub;
  StreamSubscription? _smoothedSub;
  StreamSubscription? _gapSub;
  Timer? _refreshTimer;
  bool _dirty = false;

  List<Offset>? _rawPoints;
  List<Offset>? _smoothedPoints;
  List<double>? _gapXPositions;
  double _xMin = 0, _xMax = 60, _yMin = 50, _yMax = 120;

  static const _refreshInterval = Duration(milliseconds: 100);

  @override
  void initState() {
    super.initState();
    _subscribe();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      if (_dirty && mounted) {
        _dirty = false;
        _rebuild();
        setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(RollingHrChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rawHrStream != widget.rawHrStream ||
        oldWidget.smoothedHrStream != widget.smoothedHrStream ||
        oldWidget.bleGapStream != widget.bleGapStream) {
      _rawSub?.cancel();
      _smoothedSub?.cancel();
      _gapSub?.cancel();
      _subscribe();
    }
  }

  void _subscribe() {
    final ticksPerSecond = pow(10, -widget.timestampExponent).toDouble();
    _rawSub = widget.rawHrStream.listen((event) {
      final (ts, value) = event;
      if (!value.isFinite) return;
      _rawData.addLast(_Pt(ts, value));
      _trim(_rawData, ts, ticksPerSecond);
      _dirty = true;
    });
    _smoothedSub = widget.smoothedHrStream.listen((event) {
      final (ts, value) = event;
      if (!value.isFinite) return;
      _smoothedData.addLast(_Pt(ts, value));
      _trim(_smoothedData, ts, ticksPerSecond);
      _dirty = true;
    });
    if (widget.bleGapStream != null) {
      _gapSub = widget.bleGapStream!.listen((ts) {
        _gapTimestamps.addLast(ts);
        // Trim old gap timestamps to time window.
        final cutoff = ts - (widget.timeWindow * ticksPerSecond).round();
        while (_gapTimestamps.isNotEmpty && _gapTimestamps.first < cutoff) {
          _gapTimestamps.removeFirst();
        }
        _dirty = true;
      });
    }
  }

  void _trim(Queue<_Pt> q, int latestTs, double ticksPerSecond) {
    final cutoff = latestTs - (widget.timeWindow * ticksPerSecond).round();
    while (q.isNotEmpty && q.first.ts < cutoff) {
      q.removeFirst();
    }
  }

  void _rebuild() {
    _rawPoints = _toOffsets(_rawData);
    _smoothedPoints = _toOffsets(_smoothedData);

    // Convert gap timestamps to X positions (seconds from first data point).
    final allData = [..._rawData, ..._smoothedData];
    if (allData.isNotEmpty && _gapTimestamps.isNotEmpty) {
      final firstTs = allData.map((p) => p.ts).reduce(min);
      final sPerTick = pow(10, widget.timestampExponent).toDouble();
      _gapXPositions = _gapTimestamps
          .map((ts) => (ts - firstTs) * sPerTick)
          .toList(growable: false);
    } else {
      _gapXPositions = null;
    }

    // Compute shared Y range from both datasets.
    var yMinD = double.infinity;
    var yMaxD = double.negativeInfinity;
    for (final pts in [_rawPoints, _smoothedPoints]) {
      if (pts == null) continue;
      for (final p in pts) {
        if (p.dy < yMinD) yMinD = p.dy;
        if (p.dy > yMaxD) yMaxD = p.dy;
      }
    }
    if (!yMinD.isFinite) yMinD = 50;
    if (!yMaxD.isFinite) yMaxD = 120;
    if (yMinD >= yMaxD) {
      yMinD -= 5;
      yMaxD += 5;
    }
    // Round to nice margins.
    _yMin = (yMinD - 5).floorToDouble();
    _yMax = (yMaxD + 5).ceilToDouble();

    _xMin = 0;
    _xMax = widget.timeWindow.toDouble();
    final allPts = [...?_rawPoints, ...?_smoothedPoints];
    if (allPts.isNotEmpty) {
      _xMax = max(_xMax, allPts.map((p) => p.dx).reduce(max));
    }
  }

  List<Offset>? _toOffsets(Queue<_Pt> q) {
    if (q.length < 2) return null;
    final first = q.first.ts;
    final sPerTick = pow(10, widget.timestampExponent).toDouble();
    return q
        .map((p) => Offset((p.ts - first) * sPerTick, p.value))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    if ((_rawPoints == null || _rawPoints!.length < 2) &&
        (_smoothedPoints == null || _smoothedPoints!.length < 2)) {
      return Center(
        child: Text(
          'Waiting for HR data...',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }

    return RepaintBoundary(
      child: CustomPaint(
        painter: _DualLinePainter(
          rawPoints: _rawPoints,
          smoothedPoints: _smoothedPoints,
          gapXPositions: _gapXPositions,
          xMin: _xMin,
          xMax: _xMax,
          yMin: _yMin,
          yMax: _yMax,
        ),
        size: Size.infinite,
      ),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _rawSub?.cancel();
    _smoothedSub?.cancel();
    _gapSub?.cancel();
    super.dispose();
  }
}

class _DualLinePainter extends CustomPainter {
  final List<Offset>? rawPoints;
  final List<Offset>? smoothedPoints;
  final List<double>? gapXPositions;
  final double xMin, xMax, yMin, yMax;

  _DualLinePainter({
    required this.rawPoints,
    required this.smoothedPoints,
    this.gapXPositions,
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final xRange = xMax - xMin;
    final yRange = yMax - yMin;
    if (xRange <= 0 || yRange <= 0) return;

    const leftMargin = 36.0;
    const bottomMargin = 20.0;
    final chartWidth = size.width - leftMargin;
    final chartHeight = size.height - bottomMargin;
    if (chartWidth <= 0 || chartHeight <= 0) return;

    double toX(double t) => leftMargin + ((t - xMin) / xRange) * chartWidth;
    double toY(double v) => chartHeight - ((v - yMin) / yRange) * chartHeight;

    // BLE gap markers (yellow vertical lines spanning the full chart).
    if (gapXPositions != null && gapXPositions!.isNotEmpty) {
      final gapPaint = Paint()
        ..color = const Color(0xCCFFB300)
        ..strokeWidth = 2.0;
      for (final gx in gapXPositions!) {
        final px = toX(gx);
        if (px >= leftMargin && px <= size.width) {
          canvas.drawLine(Offset(px, 0), Offset(px, chartHeight), gapPaint);
        }
      }
    }

    // Grid.
    final gridPaint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.18)
      ..strokeWidth = 0.5;
    final axisStyle = TextStyle(color: Colors.grey.shade600, fontSize: 9);

    // X axis (time).
    final xStep = _niceStep(xRange, 5);
    var tx = (xMin / xStep).ceilToDouble() * xStep;
    while (tx <= xMax) {
      final px = toX(tx);
      canvas.drawLine(Offset(px, 0), Offset(px, chartHeight), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: '${tx.toInt()}s', style: axisStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(px - tp.width / 2, chartHeight + 3));
      tx += xStep;
    }

    // Y axis (BPM).
    final yStep = _niceStep(yRange, 4);
    var ty = (yMin / yStep).ceilToDouble() * yStep;
    while (ty <= yMax) {
      final py = toY(ty);
      canvas.drawLine(
          Offset(leftMargin, py), Offset(size.width, py), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: '${ty.toInt()}', style: axisStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
          canvas, Offset(leftMargin - tp.width - 3, py - tp.height / 2));
      ty += yStep;
    }

    // Raw HR line (grey, thin, dotted-like).
    if (rawPoints != null && rawPoints!.length >= 2) {
      final rawPaint = Paint()
        ..color = Colors.grey.shade400
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;
      _drawLine(canvas, rawPoints!, toX, toY, chartHeight, rawPaint);

      // Draw raw HR as small dots at each data point.
      final dotPaint = Paint()
        ..color = Colors.grey.shade500
        ..style = PaintingStyle.fill;
      for (final p in rawPoints!) {
        final px = toX(p.dx);
        final py = toY(p.dy).clamp(0.0, chartHeight);
        canvas.drawCircle(Offset(px, py), 2.0, dotPaint);
      }
    }

    // Smoothed HR line (bold red).
    if (smoothedPoints != null && smoothedPoints!.length >= 2) {
      final smoothPaint = Paint()
        ..color = const Color(0xFFE53935)
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      _drawLine(canvas, smoothedPoints!, toX, toY, chartHeight, smoothPaint);
    }

    // Legend.
    const legendY = 4.0;
    final legendX = leftMargin + 4;
    // Raw legend.
    canvas.drawCircle(
        Offset(legendX, legendY + 5), 3, Paint()..color = Colors.grey.shade500);
    final rawLabel = TextPainter(
      text: TextSpan(text: ' RR-HR', style: axisStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    rawLabel.paint(canvas, Offset(legendX + 5, legendY));

    // Smoothed legend.
    final smoothLegendX = legendX + rawLabel.width + 20;
    canvas.drawCircle(Offset(smoothLegendX, legendY + 5), 3,
        Paint()..color = const Color(0xFFE53935));
    final smoothLabel = TextPainter(
      text: TextSpan(text: ' Kalman', style: axisStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    smoothLabel.paint(canvas, Offset(smoothLegendX + 5, legendY));

    // Gap legend.
    if (gapXPositions != null && gapXPositions!.isNotEmpty) {
      final gapLegendX = smoothLegendX + smoothLabel.width + 20;
      canvas.drawLine(
        Offset(gapLegendX, legendY + 2),
        Offset(gapLegendX, legendY + 9),
        Paint()
          ..color = const Color(0xCCFFB300)
          ..strokeWidth = 2.0,
      );
      final gapLabel = TextPainter(
        text: TextSpan(text: ' BLE Gap', style: axisStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      gapLabel.paint(canvas, Offset(gapLegendX + 3, legendY));
    }
  }

  void _drawLine(Canvas canvas, List<Offset> pts,
      double Function(double) toX, double Function(double) toY,
      double chartHeight, Paint paint) {
    final path = Path();
    var first = true;
    for (final p in pts) {
      final px = toX(p.dx);
      final py = toY(p.dy).clamp(0.0, chartHeight);
      if (first) {
        path.moveTo(px, py);
        first = false;
      } else {
        path.lineTo(px, py);
      }
    }
    canvas.drawPath(path, paint);
  }

  double _niceStep(double range, int targetTicks) {
    final rough = range / targetTicks;
    final magnitude = pow(10, (log(rough) / ln10).floorToDouble()).toDouble();
    final residual = rough / magnitude;
    if (residual <= 1.5) return magnitude;
    if (residual <= 3.5) return magnitude * 2;
    if (residual <= 7.5) return magnitude * 5;
    return magnitude * 10;
  }

  @override
  bool shouldRepaint(covariant _DualLinePainter oldDelegate) => true;
}

class _Pt {
  final int ts;
  final double value;
  _Pt(this.ts, this.value);
}
