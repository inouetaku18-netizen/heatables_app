import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:open_wearable/apps/calmables/model/ppg_filter.dart';
import 'package:open_wearable/apps/calmables/model/calmables_pwm.dart';

enum ControllerState {
  idle,
  hrAboveBaseline,
  cooldown,
  signalUnstable,
}

enum SignalQuality {
  good,
  fair,
  bad,
  unavailable,
}

class AutopilotPage extends StatefulWidget {
  final Stream<double?>? heartRateStream;
  final int initialPwmValue;
  final int initialHrThresholdMin;
  final int initialHrThresholdMax;
  final ControllerState currentState;
  final Stream<PpgSignalQuality>? signalQualityStream;

  const AutopilotPage({
    super.key,
    required this.heartRateStream,
    required this.initialPwmValue,
    required this.initialHrThresholdMin,
    required this.initialHrThresholdMax,
    required this.currentState,
    this.signalQualityStream,
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

  late int hrThresholdMin;
  late int hrThresholdMax;

  late TextEditingController _minController;
  late TextEditingController _maxController;

  late SignalQuality currentSignalQuality;
  StreamSubscription<PpgSignalQuality>? _signalQualitySubscription;

  ControllerState getCurrentControllerState() {
    // Signal Unstable
    if (currentSignalQuality == SignalQuality.bad ||
        currentSignalQuality == SignalQuality.unavailable) {
      return ControllerState.signalUnstable;
    }

    // IDLE
    if (currentPwm == 0 && heartRateSpots.isEmpty) {
      return ControllerState.idle;
    }

    double? latestHr = heartRateSpots.isNotEmpty ? heartRateSpots.last.y : null;

    if (latestHr != null) {
      if (latestHr > hrThresholdMin) {
        return ControllerState.hrAboveBaseline;
      } else if (latestHr < hrThresholdMin && currentPwm == 0) {
        return ControllerState.cooldown;
      }
    }

    // Default IDLE
    return ControllerState.idle;
  }

  @override
  void initState() {
    super.initState();
    currentPwm = widget.initialPwmValue;

    hrThresholdMin = widget.initialHrThresholdMin;
    hrThresholdMax = widget.initialHrThresholdMax;

    _minController = TextEditingController(text: hrThresholdMin.toString());
    _maxController = TextEditingController(text: hrThresholdMax.toString());

    currentSignalQuality = SignalQuality.good;

    _signalQualitySubscription = widget.signalQualityStream?.listen((quality) {
      setState(() {
        currentSignalQuality = _convertPpgToLocalSignalQuality(quality);
      });
    });

    hrSubscription = widget.heartRateStream?.listen((bpm) {
      if (bpm != null && bpm.isFinite) {
        setState(() {
          time += 1.0;
          heartRateSpots.add(FlSpot(time, bpm));
          if (heartRateSpots.length > historyLength) {
            heartRateSpots.removeAt(0);
          }
          currentPwm = AutopilotController.pwmFromHeartRate(
              bpm, hrThresholdMin.toDouble(), hrThresholdMax.toDouble());
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
    _minController.dispose();
    _maxController.dispose();
    hrSubscription?.cancel();
    _signalQualitySubscription?.cancel();
    super.dispose();
  }

  SignalQuality _convertPpgToLocalSignalQuality(PpgSignalQuality quality) {
    switch (quality) {
      case PpgSignalQuality.good:
        return SignalQuality.good;
      case PpgSignalQuality.fair:
        return SignalQuality.fair;
      case PpgSignalQuality.bad:
        return SignalQuality.bad;
      case PpgSignalQuality.unavailable:
        return SignalQuality.unavailable;
    }
  }

  Future<bool> _onWillPop() async {
    // 戻る際に現在の閾値を親画面に返す
    Navigator.of(context).pop({'min': hrThresholdMin, 'max': hrThresholdMax});
    return false; // popは自分で行ったのでfalseを返す
  }

  Widget _buildChart({
    required List<FlSpot> spots,
    required Color lineColor,
    required double minY,
    required double maxY,
    required String leftTitle,
    required bool showBottomTitles,
    double height = 300,
    double? thresholdMin,
    double? thresholdMax,
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
              height: height + 30, // 横軸ラベルの分だけ余白確保
              child: Column(
                children: [
                  SizedBox(
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
                              reservedSize: 20,
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
                        extraLinesData: ExtraLinesData(
                          horizontalLines: [
                            if (thresholdMin != null)
                              HorizontalLine(
                                y: thresholdMin,
                                color: Colors.red,
                                strokeWidth: 1,
                                dashArray: [5, 5], // 破線
                                label: HorizontalLineLabel(
                                  show: true,
                                  alignment: Alignment.topRight,
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 10,
                                  ),
                                  labelResolver: (_) =>
                                      'Min: ${thresholdMin.toInt()}',
                                ),
                              ),
                            if (thresholdMax != null)
                              HorizontalLine(
                                y: thresholdMax,
                                color: Colors.red,
                                strokeWidth: 1,
                                dashArray: [5, 5], // 破線
                                label: HorizontalLineLabel(
                                  show: true,
                                  alignment: Alignment.bottomRight,
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 10,
                                  ),
                                  labelResolver: (_) =>
                                      'Max: ${thresholdMax.toInt()}',
                                ),
                              ),
                          ],
                        ),
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
                  //const SizedBox(height: 12),
                  const Text('time (sec)',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onWillPop, // 戻る際に閾値を返す
      child: Scaffold(
        appBar: AppBar(
          title: const Text('HR-based Mode'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => _onWillPop(),
          ),
        ),
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              // 心拍数の閾値入力UI
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'HR Threshold Min',
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 12),
                      ),
                      controller: _minController,
                      onChanged: (value) {
                        final val = int.tryParse(value);
                        if (val != null && val >= 40 && val <= hrThresholdMax) {
                          setState(() {
                            hrThresholdMin = val;
                          });
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'HR Threshold Max',
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 12),
                      ),
                      controller: _maxController,
                      onChanged: (value) {
                        final val = int.tryParse(value);
                        if (val != null &&
                            val <= 120 &&
                            val >= hrThresholdMin) {
                          setState(() {
                            hrThresholdMax = val;
                          });
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Heart Rate and PWM History',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 200, // 元の半分の高さ
                      child: _buildChart(
                        spots: heartRateSpots,
                        lineColor: Colors.red,
                        minY: 40,
                        maxY: 120,
                        leftTitle: 'BPM',
                        showBottomTitles: true,
                        height: 170,
                        thresholdMin: hrThresholdMin.toDouble(),
                        thresholdMax: hrThresholdMax.toDouble(),
                      ),
                    ),
                    const SizedBox(height: 30), // 縦の間隔も半分に
                    SizedBox(
                      height: 200, // 元の半分の高さ
                      child: _buildChart(
                        spots: pwmSpots,
                        lineColor: Colors.blue,
                        minY: 0,
                        maxY: 255,
                        leftTitle: 'PWM',
                        showBottomTitles: true,
                        height: 170, // 半分
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: const [
                        LegendItem(
                            color: Colors.red, label: 'Heart Rate (BPM)'),
                        LegendItem(color: Colors.blue, label: 'PWM'),
                      ],
                    ),

                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Text(
                            'Current Controller State:',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Builder(
                            builder: (context) {
                              final state = getCurrentControllerState();
                              Color stateColor;
                              String stateText;
                              switch (state) {
                                case ControllerState.idle:
                                  stateColor = Colors.black;
                                  stateText = 'IDLE';
                                  break;
                                case ControllerState.hrAboveBaseline:
                                  stateColor = Color(0xFF009682);
                                  stateText = 'HR ABOVE BASELINE';
                                  break;
                                case ControllerState.cooldown:
                                  stateColor = Colors.blue;
                                  stateText = 'COOLDOWN';
                                  break;
                                case ControllerState.signalUnstable:
                                  stateColor = Colors.red;
                                  stateText = 'SIGNAL UNSTABLE';
                                  break;
                              }
                              return Text(
                                stateText,
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                  color: stateColor,
                                ),
                                textAlign: TextAlign.center,
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
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
