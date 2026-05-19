import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/material.dart';

const Color _rawLegendColor = Color(0xFF9E9E9E);
const Color _filteredLegendColor = Color(0xFFE53935);
const Color _gapLegendColor = Color(0xCCFFB300);

/// A rolling chart that overlays raw and smoothed heart rate over time.
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

class RollingHrChartLegend extends StatelessWidget {
  final bool showBleGap;

  const RollingHrChartLegend({
    super.key,
    this.showBleGap = false,
  });

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        );

    return Wrap(
      spacing: 14,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _LegendItem(
          marker: Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: _rawLegendColor,
              shape: BoxShape.circle,
            ),
          ),
          label: 'Raw',
          textStyle: textStyle,
        ),
        _LegendItem(
          marker: Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: _filteredLegendColor,
              shape: BoxShape.circle,
            ),
          ),
          label: 'Filtered',
          textStyle: textStyle,
        ),
        if (showBleGap)
          _LegendItem(
            marker: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: _gapLegendColor,
              ),
            ),
            label: 'BLE Gap',
            textStyle: textStyle,
          ),
      ],
    );
  }
}

class _RollingHrChartState extends State<RollingHrChart> {
  final Queue<_Pt> _rawData = Queue<_Pt>();
  final Queue<_Pt> _smoothedData = Queue<_Pt>();
  final Queue<int> _gapTimestamps = Queue<int>();

  StreamSubscription<(int, double)>? _rawSub;
  StreamSubscription<(int, double)>? _smoothedSub;
  StreamSubscription<int>? _gapSub;
  Timer? _refreshTimer;
  bool _dirty = false;

  List<Offset>? _rawPoints;
  List<Offset>? _smoothedPoints;
  List<double>? _gapXPositions;
  double _xMin = 0;
  double _xMax = 60;
  double _yMin = 50;
  double _yMax = 120;

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
  void didUpdateWidget(covariant RollingHrChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rawHrStream != widget.rawHrStream ||
        oldWidget.smoothedHrStream != widget.smoothedHrStream ||
        oldWidget.bleGapStream != widget.bleGapStream) {
      _rawSub?.cancel();
      _smoothedSub?.cancel();
      _gapSub?.cancel();
      _rawData.clear();
      _smoothedData.clear();
      _gapTimestamps.clear();
      _subscribe();
    }
  }

  void _subscribe() {
    final ticksPerSecond = pow(10, -widget.timestampExponent).toDouble();

    _rawSub = widget.rawHrStream.listen((event) {
      final (ts, value) = event;
      if (!value.isFinite) {
        return;
      }
      _rawData.addLast(_Pt(ts, value));
      _trim(_rawData, ts, ticksPerSecond);
      _dirty = true;
    });

    _smoothedSub = widget.smoothedHrStream.listen((event) {
      final (ts, value) = event;
      if (!value.isFinite) {
        return;
      }
      _smoothedData.addLast(_Pt(ts, value));
      _trim(_smoothedData, ts, ticksPerSecond);
      _dirty = true;
    });

    if (widget.bleGapStream != null) {
      _gapSub = widget.bleGapStream!.listen((ts) {
        _gapTimestamps.addLast(ts);
        final cutoff = ts - (widget.timeWindow * ticksPerSecond).round();
        while (_gapTimestamps.isNotEmpty && _gapTimestamps.first < cutoff) {
          _gapTimestamps.removeFirst();
        }
        _dirty = true;
      });
    }
  }

  void _trim(Queue<_Pt> points, int latestTs, double ticksPerSecond) {
    final cutoff = latestTs - (widget.timeWindow * ticksPerSecond).round();
    while (points.isNotEmpty && points.first.ts < cutoff) {
      points.removeFirst();
    }
  }

  void _rebuild() {
    _rawPoints = _toOffsets(_rawData);
    _smoothedPoints = _toOffsets(_smoothedData);

    final allData = [..._rawData, ..._smoothedData];
    if (allData.isNotEmpty && _gapTimestamps.isNotEmpty) {
      final firstTs = allData.map((point) => point.ts).reduce(min);
      final secondsPerTick = pow(10, widget.timestampExponent).toDouble();
      _gapXPositions = _gapTimestamps
          .map((ts) => (ts - firstTs) * secondsPerTick)
          .toList(growable: false);
    } else {
      _gapXPositions = null;
    }

    var yMinD = double.infinity;
    var yMaxD = double.negativeInfinity;
    for (final points in [_rawPoints, _smoothedPoints]) {
      if (points == null) {
        continue;
      }
      for (final point in points) {
        if (point.dy < yMinD) {
          yMinD = point.dy;
        }
        if (point.dy > yMaxD) {
          yMaxD = point.dy;
        }
      }
    }
    if (!yMinD.isFinite) {
      yMinD = 50;
    }
    if (!yMaxD.isFinite) {
      yMaxD = 120;
    }
    if (yMinD >= yMaxD) {
      yMinD -= 5;
      yMaxD += 5;
    }
    _yMin = (yMinD - 5).floorToDouble();
    _yMax = (yMaxD + 5).ceilToDouble();

    _xMin = 0;
    _xMax = widget.timeWindow.toDouble();
    final allPoints = [...?_rawPoints, ...?_smoothedPoints];
    if (allPoints.isNotEmpty) {
      _xMax = max(_xMax, allPoints.map((point) => point.dx).reduce(max));
    }
  }

  List<Offset>? _toOffsets(Queue<_Pt> points) {
    if (points.length < 2) {
      return null;
    }
    final first = points.first.ts;
    final secondsPerTick = pow(10, widget.timestampExponent).toDouble();
    return points
        .map(
          (point) => Offset((point.ts - first) * secondsPerTick, point.value),
        )
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
  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;

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
    if (size.isEmpty) {
      return;
    }

    final xRange = xMax - xMin;
    final yRange = yMax - yMin;
    if (xRange <= 0 || yRange <= 0) {
      return;
    }

    const leftMargin = 36.0;
    const bottomMargin = 20.0;
    final chartWidth = size.width - leftMargin;
    final chartHeight = size.height - bottomMargin;
    if (chartWidth <= 0 || chartHeight <= 0) {
      return;
    }

    double toX(double t) => leftMargin + ((t - xMin) / xRange) * chartWidth;
    double toY(double v) => chartHeight - ((v - yMin) / yRange) * chartHeight;

    if (gapXPositions != null && gapXPositions!.isNotEmpty) {
      final gapPaint = Paint()
        ..color = _gapLegendColor
        ..strokeWidth = 2.0;
      for (final gx in gapXPositions!) {
        final px = toX(gx);
        if (px >= leftMargin && px <= size.width) {
          canvas.drawLine(Offset(px, 0), Offset(px, chartHeight), gapPaint);
        }
      }
    }

    final gridPaint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.18)
      ..strokeWidth = 0.5;
    final axisStyle = TextStyle(color: Colors.grey.shade600, fontSize: 9);

    final xStep = _niceStep(xRange, 5);
    var tx = (xMin / xStep).ceilToDouble() * xStep;
    while (tx <= xMax) {
      final px = toX(tx);
      canvas.drawLine(Offset(px, 0), Offset(px, chartHeight), gridPaint);
      final painter = TextPainter(
        text: TextSpan(text: '${tx.toInt()}s', style: axisStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, Offset(px - painter.width / 2, chartHeight + 3));
      tx += xStep;
    }

    final yStep = _niceStep(yRange, 4);
    var ty = (yMin / yStep).ceilToDouble() * yStep;
    while (ty <= yMax) {
      final py = toY(ty);
      canvas.drawLine(
        Offset(leftMargin, py),
        Offset(size.width, py),
        gridPaint,
      );
      final painter = TextPainter(
        text: TextSpan(text: '${ty.toInt()}', style: axisStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset(leftMargin - painter.width - 3, py - painter.height / 2),
      );
      ty += yStep;
    }

    if (rawPoints != null && rawPoints!.length >= 2) {
      final rawPaint = Paint()
        ..color = Colors.grey.shade400
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;
      _drawLine(canvas, rawPoints!, toX, toY, chartHeight, rawPaint);

      final dotPaint = Paint()
        ..color = Colors.grey.shade500
        ..style = PaintingStyle.fill;
      for (final point in rawPoints!) {
        final px = toX(point.dx);
        final py = toY(point.dy).clamp(0.0, chartHeight);
        canvas.drawCircle(Offset(px, py), 2.0, dotPaint);
      }
    }

    if (smoothedPoints != null && smoothedPoints!.length >= 2) {
      final smoothPaint = Paint()
        ..color = _filteredLegendColor
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      _drawLine(canvas, smoothedPoints!, toX, toY, chartHeight, smoothPaint);
    }
  }

  void _drawLine(
    Canvas canvas,
    List<Offset> points,
    double Function(double) toX,
    double Function(double) toY,
    double chartHeight,
    Paint paint,
  ) {
    final path = Path();
    var first = true;
    for (final point in points) {
      final px = toX(point.dx);
      final py = toY(point.dy).clamp(0.0, chartHeight);
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
    if (residual <= 1.5) {
      return magnitude;
    }
    if (residual <= 3.5) {
      return magnitude * 2;
    }
    if (residual <= 7.5) {
      return magnitude * 5;
    }
    return magnitude * 10;
  }

  @override
  bool shouldRepaint(covariant _DualLinePainter oldDelegate) => true;
}

class _LegendItem extends StatelessWidget {
  final Widget marker;
  final String label;
  final TextStyle? textStyle;

  const _LegendItem({
    required this.marker,
    required this.label,
    required this.textStyle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        marker,
        const SizedBox(width: 6),
        Text(label, style: textStyle),
      ],
    );
  }
}

class _Pt {
  final int ts;
  final double value;

  _Pt(this.ts, this.value);
}
