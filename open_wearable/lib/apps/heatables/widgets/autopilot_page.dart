import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:open_wearable/apps/heatables/model/heatables_pwm.dart';

class AutopilotPage extends StatefulWidget {
  final Stream<double?>? heartRateStream;
  final int initialPwmValue;

  const AutopilotPage({
    super.key,
    required this.heartRateStream,
    required this.initialPwmValue,
  });

  @override
  State<AutopilotPage> createState() => _AutopilotPageState();
}

class _AutopilotPageState extends State<AutopilotPage> {
  List<FlSpot> heartRateSpots = [];
  List<FlSpot> pwmSpots = [];
  double time = 0.0;
  StreamSubscription<double?>? hrSubscription;
  int currentPwm = 0;
  int historyLength = 30;

  @override
  void initState() {
    super.initState();
    currentPwm = widget.initialPwmValue;
    hrSubscription = widget.heartRateStream?.listen((bpm) {
      if (bpm != null && bpm.isFinite) {
        setState(() {
          time += 1.0;
          heartRateSpots.add(FlSpot(time, bpm));
          if (heartRateSpots.length > historyLength) {
            heartRateSpots.removeAt(0);
          }
          currentPwm = AutopilotController.pwmFromHeartRate(bpm);
          pwmSpots.add(FlSpot(time, currentPwm.toDouble()));
          if (pwmSpots.length > historyLength) {
            pwmSpots.removeAt(0);
          }
        });
      }
    });
  }

  @override
  void dispose() {
    hrSubscription?.cancel();
    super.dispose();
  }

  Widget _buildChart({
    required List<FlSpot> spots,
    required Color lineColor,
    required double minY,
    required double maxY,
    required String leftTitle,
    required bool showBottomTitles,
    double height = 300, // ここで高さ指定（2倍など調整可能）
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          RotatedBox(
            quarterTurns: 3,
            child: Text(
              leftTitle,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: height,
              child: LineChart(
                LineChartData(
                  minY: minY,
                  maxY: maxY,
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles:
                          SideTitles(showTitles: true, reservedSize: 40),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: showBottomTitles,
                        reservedSize: 24,
                        interval: 20,
                        getTitlesWidget: (value, meta) {
                          if (value % 20 == 0) {
                            return Text(value.toInt().toString());
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                    rightTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  gridData: FlGridData(show: true),
                  borderData: FlBorderData(show: true),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      barWidth: 2,
                      color: lineColor,
                      dotData: FlDotData(show: false),
                      belowBarData: BarAreaData(show: false),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Autopilot Mode'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.of(context).pop(); // 元のページに戻る
          },
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            const Text(
              'Heart Rate and PWM History',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: _buildChart(
                      spots: heartRateSpots,
                      lineColor: Colors.red,
                      minY: 40,
                      maxY: 120,
                      leftTitle: 'BPM',
                      showBottomTitles: true,
                      height: 300, // 2倍の縦サイズ
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: _buildChart(
                      spots: pwmSpots,
                      lineColor: Colors.blue,
                      minY: 0,
                      maxY: 255,
                      leftTitle: 'PWM',
                      showBottomTitles: true,
                      height: 300,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: const [
                LegendItem(color: Colors.red, label: 'Heart Rate (BPM)'),
                LegendItem(color: Colors.blue, label: 'PWM'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class LegendItem extends StatelessWidget {
  final Color color;
  final String label;

  const LegendItem({super.key, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(width: 16, height: 4, color: color),
        const SizedBox(width: 4),
        Text(label),
      ],
    );
  }
}
