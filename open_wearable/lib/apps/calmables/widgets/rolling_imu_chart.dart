import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:open_wearable/apps/calmables/model/ppg_filter.dart';

/// Rolling 3-axis IMU chart (X / Y / Z) over a configurable time window.
class RollingImuChart extends StatefulWidget {
  final Stream<PpgMotionSample> imuStream;
  final int timestampExponent;
  final int timeWindow;

  const RollingImuChart({
    super.key,
    required this.imuStream,
    required this.timestampExponent,
    this.timeWindow = 5,
  });

  @override
  State<RollingImuChart> createState() => _RollingImuChartState();
}

class _RollingImuChartState extends State<RollingImuChart> {
  final Queue<_ImuPt> _data = Queue();
  StreamSubscription? _sub;
  Timer? _refreshTimer;
  bool _dirty = false;

  List<Offset>? _xPoints;
  List<Offset>? _yPoints;
  List<Offset>? _zPoints;
  double _xMin = 0, _xMax = 5, _yMin = -2, _yMax = 2;

  static const _refreshInterval = Duration(milliseconds: 50);

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
  void didUpdateWidget(RollingImuChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imuStream != widget.imuStream) {
      _sub?.cancel();
      _subscribe();
    }
  }

  void _subscribe() {
    final ticksPerSecond = pow(10, -widget.timestampExponent).toDouble();
    _sub = widget.imuStream.listen((sample) {
      _data.addLast(_ImuPt(sample.timestamp, sample.x, sample.y, sample.z));
      final cutoff =
          sample.timestamp - (widget.timeWindow * ticksPerSecond).round();
      while (_data.isNotEmpty && _data.first.ts < cutoff) {
        _data.removeFirst();
      }
      _dirty = true;
    });
  }

  void _rebuild() {
    if (_data.length < 2) {
      _xPoints = null;
      _yPoints = null;
      _zPoints = null;
      return;
    }

    final firstTs = _data.first.ts;
    final sPerTick = pow(10, widget.timestampExponent).toDouble();

    final xPts = <Offset>[];
    final yPts = <Offset>[];
    final zPts = <Offset>[];
    var yMinD = double.infinity;
    var yMaxD = double.negativeInfinity;

    for (final p in _data) {
      final t = (p.ts - firstTs) * sPerTick;
      xPts.add(Offset(t, p.x));
      yPts.add(Offset(t, p.y));
      zPts.add(Offset(t, p.z));
      for (final v in [p.x, p.y, p.z]) {
        if (v < yMinD) yMinD = v;
        if (v > yMaxD) yMaxD = v;
      }
    }

    _xPoints = xPts;
    _yPoints = yPts;
    _zPoints = zPts;

    if (!yMinD.isFinite) yMinD = -2;
    if (!yMaxD.isFinite) yMaxD = 2;
    if (yMinD >= yMaxD) {
      yMinD -= 1;
      yMaxD += 1;
    }
    final margin = (yMaxD - yMinD) * 0.08;
    _yMin = yMinD - margin;
    _yMax = yMaxD + margin;
    _xMin = 0;
    _xMax = max(widget.timeWindow.toDouble(),
        xPts.isNotEmpty ? xPts.last.dx : widget.timeWindow.toDouble());
  }

  @override
  Widget build(BuildContext context) {
    if (_xPoints == null || _xPoints!.length < 2) {
      return Center(
        child: Text(
          'Waiting for IMU data...',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }

    return RepaintBoundary(
      child: CustomPaint(
        painter: _ImuPainter(
          xPoints: _xPoints,
          yPoints: _yPoints,
          zPoints: _zPoints,
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
    _sub?.cancel();
    super.dispose();
  }
}

class _ImuPainter extends CustomPainter {
  final List<Offset>? xPoints;
  final List<Offset>? yPoints;
  final List<Offset>? zPoints;
  final double xMin, xMax, yMin, yMax;

  _ImuPainter({
    required this.xPoints,
    required this.yPoints,
    required this.zPoints,
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

    const leftMargin = 40.0;
    const bottomMargin = 20.0;
    final chartWidth = size.width - leftMargin;
    final chartHeight = size.height - bottomMargin;
    if (chartWidth <= 0 || chartHeight <= 0) return;

    double toX(double t) => leftMargin + ((t - xMin) / xRange) * chartWidth;
    double toY(double v) => chartHeight - ((v - yMin) / yRange) * chartHeight;

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
        text: TextSpan(text: '${tx.toStringAsFixed(1)}s', style: axisStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(px - tp.width / 2, chartHeight + 3));
      tx += xStep;
    }

    // Y axis.
    final yStep = _niceStep(yRange, 4);
    var ty = (yMin / yStep).ceilToDouble() * yStep;
    while (ty <= yMax) {
      final py = toY(ty);
      canvas.drawLine(
          Offset(leftMargin, py), Offset(size.width, py), gridPaint);
      final tp = TextPainter(
        text: TextSpan(
            text: ty.abs() < 10
                ? ty.toStringAsFixed(1)
                : ty.toStringAsFixed(0),
            style: axisStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
          canvas, Offset(leftMargin - tp.width - 3, py - tp.height / 2));
      ty += yStep;
    }

    // Axis lines.
    const xColor = Color(0xFFE53935); // red
    const yColor = Color(0xFF43A047); // green
    const zColor = Color(0xFF1E88E5); // blue

    void drawSeries(List<Offset>? pts, Color color) {
      if (pts == null || pts.length < 2) return;
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;
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

    drawSeries(xPoints, xColor);
    drawSeries(yPoints, yColor);
    drawSeries(zPoints, zColor);

    // Legend.
    const legendY = 4.0;
    final legendX = leftMargin + 4;

    void drawLegendItem(double x, Color color, String label) {
      canvas.drawLine(
        Offset(x, legendY + 4),
        Offset(x + 10, legendY + 4),
        Paint()
          ..color = color
          ..strokeWidth = 2.0,
      );
      final tp = TextPainter(
        text: TextSpan(text: ' $label', style: axisStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x + 12, legendY));
    }

    drawLegendItem(legendX, xColor, 'X');
    drawLegendItem(legendX + 40, yColor, 'Y');
    drawLegendItem(legendX + 80, zColor, 'Z');
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
  bool shouldRepaint(covariant _ImuPainter oldDelegate) => true;
}

class _ImuPt {
  final int ts;
  final double x, y, z;
  _ImuPt(this.ts, this.x, this.y, this.z);
}
