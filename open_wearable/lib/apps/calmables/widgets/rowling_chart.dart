import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'package:flutter/material.dart';

class RollingChart extends StatefulWidget {
  final Stream<(int, double)> dataSteam;
  final Stream<List<int>>? peakTimestampsStream;
  final int timestampExponent;
  final int timeWindow; // in seconds
  final bool showXAxis;
  final bool showYAxis;
  final double? fixedMeasureMin;
  final double? fixedMeasureMax;

  const RollingChart({
    super.key,
    required this.dataSteam,
    this.peakTimestampsStream,
    required this.timestampExponent,
    required this.timeWindow,
    this.showXAxis = true,
    this.showYAxis = true,
    this.fixedMeasureMin,
    this.fixedMeasureMax,
  });

  @override
  State<RollingChart> createState() => _RollingChartState();
}

class _RollingChartState extends State<RollingChart> {
  final Queue<_RawChartPoint> _rawData = Queue();
  StreamSubscription? _subscription;
  StreamSubscription? _peakSubscription;
  Timer? _refreshTimer;
  bool _dirty = false;

  // Pre-computed paint data for the CustomPainter.
  List<Offset>? _normalizedPoints;
  Set<int> _peakTimestamps = {};
  double _xMin = 0;
  double _xMax = 5;
  double _yMin = -1;
  double _yMax = 1;

  static const _refreshInterval = Duration(milliseconds: 20); // ~50 fps

  @override
  void initState() {
    super.initState();
    _listenToStream();
    _listenToPeaks();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      if (_dirty && mounted) {
        _dirty = false;
        _rebuildPaintData();
        setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(RollingChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dataSteam != widget.dataSteam) {
      _subscription?.cancel();
      _listenToStream();
    }
    if (oldWidget.peakTimestampsStream != widget.peakTimestampsStream) {
      _peakSubscription?.cancel();
      _listenToPeaks();
    }
  }

  void _listenToStream() {
    _subscription = widget.dataSteam.listen((event) {
      final (timestamp, value) = event;
      if (!value.isFinite) return;

      _rawData.addLast(_RawChartPoint(timestamp, value));

      final ticksPerSecond = pow(10, -widget.timestampExponent).toDouble();
      final cutoffTime =
          timestamp - (widget.timeWindow * ticksPerSecond).round();
      while (_rawData.isNotEmpty && _rawData.first.timestamp < cutoffTime) {
        _rawData.removeFirst();
      }

      _dirty = true;
    });
  }

  void _listenToPeaks() {
    _peakSubscription = widget.peakTimestampsStream?.listen((timestamps) {
      _peakTimestamps = timestamps.toSet();
      _dirty = true;
    });
  }

  void _rebuildPaintData() {
    if (_rawData.length < 2) {
      _normalizedPoints = null;
      return;
    }

    final firstTimestamp = _rawData.first.timestamp;
    final secondsPerTick = pow(10, widget.timestampExponent).toDouble();

    var yMinData = double.infinity;
    var yMaxData = double.negativeInfinity;
    final points = <Offset>[];

    for (final p in _rawData) {
      if (!p.value.isFinite) continue;
      final t = (p.timestamp - firstTimestamp) * secondsPerTick;
      points.add(Offset(t, p.value));
      if (p.value < yMinData) yMinData = p.value;
      if (p.value > yMaxData) yMaxData = p.value;
    }

    if (points.length < 2) {
      _normalizedPoints = null;
      return;
    }

    _xMin = 0;
    _xMax = max(
      widget.timeWindow.toDouble(),
      points.last.dx,
    );

    var yMin = widget.fixedMeasureMin ?? yMinData;
    var yMax = widget.fixedMeasureMax ?? yMaxData;
    if (yMin >= yMax) {
      final center = yMin;
      final pad = max(center.abs() * 0.05, 1.0);
      yMin = center - pad;
      yMax = center + pad;
    }
    _yMin = yMin;
    _yMax = yMax;
    _normalizedPoints = points;
  }

  @override
  Widget build(BuildContext context) {
    final points = _normalizedPoints;
    if (points == null || points.length < 2) {
      return Center(
        child: Text(
          'Waiting for signal...',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }

    return RepaintBoundary(
      child: CustomPaint(
        painter: _RollingChartPainter(
          points: points,
          peakTimestamps: _peakTimestamps,
          rawData: _rawData,
          timestampExponent: widget.timestampExponent,
          xMin: _xMin,
          xMax: _xMax,
          yMin: _yMin,
          yMax: _yMax,
          lineColor: const Color(0xFFE53935),
          showXAxis: widget.showXAxis,
          showYAxis: widget.showYAxis,
        ),
        size: Size.infinite,
      ),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _subscription?.cancel();
    _peakSubscription?.cancel();
    super.dispose();
  }
}

class _RollingChartPainter extends CustomPainter {
  final List<Offset> points;
  final Set<int> peakTimestamps;
  final Queue<_RawChartPoint> rawData;
  final int timestampExponent;
  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;
  final Color lineColor;
  final bool showXAxis;
  final bool showYAxis;

  _RollingChartPainter({
    required this.points,
    required this.peakTimestamps,
    required this.rawData,
    required this.timestampExponent,
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
    required this.lineColor,
    required this.showXAxis,
    required this.showYAxis,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2 || size.isEmpty) return;

    final xRange = xMax - xMin;
    final yRange = yMax - yMin;
    if (xRange <= 0 || yRange <= 0) return;

    // Chart area with optional margins for axes.
    final leftMargin = showYAxis ? 32.0 : 0.0;
    final bottomMargin = showXAxis ? 20.0 : 0.0;
    final chartWidth = size.width - leftMargin;
    final chartHeight = size.height - bottomMargin;
    if (chartWidth <= 0 || chartHeight <= 0) return;

    double toX(double t) => leftMargin + ((t - xMin) / xRange) * chartWidth;
    double toY(double v) => chartHeight - ((v - yMin) / yRange) * chartHeight;

    // Draw grid lines.
    final gridPaint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.18)
      ..strokeWidth = 0.5;

    if (showXAxis) {
      final tickStep = _niceStep(xRange, 5);
      final axisStyle = TextStyle(color: Colors.grey.shade600, fontSize: 9);
      var tx = (xMin / tickStep).ceilToDouble() * tickStep;
      while (tx <= xMax) {
        final px = toX(tx);
        canvas.drawLine(Offset(px, 0), Offset(px, chartHeight), gridPaint);
        final tp = TextPainter(
          text: TextSpan(text: '${tx.toInt()}s', style: axisStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(px - tp.width / 2, chartHeight + 3));
        tx += tickStep;
      }
    }

    if (showYAxis) {
      final tickStep = _niceStep(yRange, 4);
      final axisStyle = TextStyle(color: Colors.grey.shade600, fontSize: 9);
      var ty = (yMin / tickStep).ceilToDouble() * tickStep;
      while (ty <= yMax) {
        final py = toY(ty);
        canvas.drawLine(Offset(leftMargin, py), Offset(size.width, py), gridPaint);
        final label = ty.abs() < 1
            ? ty.toStringAsFixed(2)
            : ty.toStringAsFixed(1);
        final tp = TextPainter(
          text: TextSpan(text: label, style: axisStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(leftMargin - tp.width - 3, py - tp.height / 2));
        ty += tickStep;
      }
    }

    // Draw the signal line.
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    final path = Path();
    var first = true;
    for (final p in points) {
      final px = toX(p.dx);
      final py = toY(p.dy).clamp(0.0, chartHeight);
      if (first) {
        path.moveTo(px, py);
        first = false;
      } else {
        path.lineTo(px, py);
      }
    }
    canvas.drawPath(path, linePaint);

    // Draw peak markers.
    if (peakTimestamps.isNotEmpty && rawData.isNotEmpty) {
      final peakPaint = Paint()
        ..color = const Color(0xFF1565C0)
        ..style = PaintingStyle.fill;
      final firstTimestamp = rawData.first.timestamp;
      final secondsPerTick = pow(10, timestampExponent).toDouble();

      for (final p in rawData) {
        if (!peakTimestamps.contains(p.timestamp)) continue;
        final t = (p.timestamp - firstTimestamp) * secondsPerTick;
        final px = toX(t);
        final py = toY(p.value).clamp(0.0, chartHeight);
        canvas.drawCircle(Offset(px, py), 3.5, peakPaint);
      }
    }
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
  bool shouldRepaint(covariant _RollingChartPainter oldDelegate) => true;
}

class _RawChartPoint {
  final int timestamp;
  final double value;

  _RawChartPoint(this.timestamp, this.value);
}
