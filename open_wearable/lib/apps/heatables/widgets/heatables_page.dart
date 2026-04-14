import 'dart:async';
//import 'dart:convert';
//import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';

//import 'package:universal_ble/universal_ble.dart';

import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:open_wearable/apps/heatables/model/ppg_filter.dart';
import 'package:open_wearable/apps/heatables/model/heatables_pwm.dart';
import 'package:open_wearable/apps/heatables/widgets/rowling_chart.dart';
import 'package:open_wearable/apps/heatables/widgets/autopilot_page.dart';
import 'package:open_wearable/models/wearable_display_group.dart';
import 'package:open_wearable/view_models/sensor_configuration_provider.dart';
import 'package:open_wearable/widgets/devices/devices_page.dart';
import 'package:provider/provider.dart';

class HeatablesPage extends StatefulWidget {
  final Wearable wearable;
  final Sensor ppgSensor;
  final Sensor? opticalTemperatureSensor;
  final Sensor? accelerometerSensor;
  final List<Wearable> connectedDevices;

  const HeatablesPage({
    super.key,
    required this.wearable,
    required this.ppgSensor,
    this.opticalTemperatureSensor,
    this.accelerometerSensor,
    this.connectedDevices = const [],
  });

  @override
  State<HeatablesPage> createState() => _HeatablesPageState();
}

enum ControlMode { manual, autopilot }

class _HeatablesPageState extends State<HeatablesPage> {
  PpgFilter? _ppgFilter;
  Stream<(int, double)>? _displayPpgSignalStream;
  Stream<double?>? _heartRateStream;
  Stream<double?>? _hrvStream;
  Stream<double?>? _hrvLfhfStream;
  Stream<double?>? _temperatureStream;
  Stream<PpgSignalQuality>? _signalQualityStream;
  SensorConfigurationProvider? _sensorConfigProvider;

  //final WearableManager _wearableManager = WearableManager();
  ControlMode _controlMode = ControlMode.manual;
  StreamSubscription<double?>? _heartRateSubscription;

  late Wearable heatablesDevice;

  // ESP32(Heatables)用スライダー値（0-255）
  int heatablesSliderValue = 0;

  final String _characteristicUuid = "6bb7da44-e8b9-3e3f-6d5a-e212c378d2df";
  final String _serviceUuid = "a542957a-968b-91fa-254c-62c7a367a692";

  //心拍数の平均の表示
  List<double> heartRateHistory = [];
  List<double> hrvHistory = [];
  static const int maxHistoryLength = 5;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      heatablesDevice = widget.connectedDevices.firstWhere(
        (device) => device.name.toLowerCase().contains('heatables'),
      );

      _initializePipeline();
    });

    //startOpenEarableScan();
  }

  @override
  void dispose() {
    final configProvider = _sensorConfigProvider;
    _heartRateSubscription?.cancel();
    if (configProvider != null) {
      unawaited(configProvider.turnOffAllSensors());
    }
    _ppgFilter?.dispose();
    super.dispose();
  }

  void _onModeChanged(ControlMode mode) {
    if (_controlMode == mode) return;
    setState(() {
      _controlMode = mode;
      heatablesSliderValue = 0;
      pwmHistory.clear();
    });
    sendDataToHeatables([0]);

    if (mode == ControlMode.autopilot) {
      // Autopilot画面へ遷移
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => AutopilotPage(
            heartRateStream: _heartRateStream,
            initialPwmValue: heatablesSliderValue,
          ),
        ),
      );
      // Autopilot開始：心拍数ストリーム監視してPWM計算＆送信
      _heartRateSubscription = _heartRateStream?.listen((bpm) {
        if (bpm != null && bpm.isFinite) {
          final pwmValue = AutopilotController.pwmFromHeartRate(bpm);
          sendDataToHeatables([pwmValue]);
          setState(() {
            heatablesSliderValue = pwmValue;
            pwmHistory.add(pwmValue);
            if (pwmHistory.length > pwmHistoryLength) {
              pwmHistory.removeAt(0);
            }
          });
        }
      });
    } else {
      // Manualモード時は心拍数購読解除
      _heartRateSubscription?.cancel();
      _heartRateSubscription = null;
    }
  }

  // PWM履歴リストを追加
  List<int> pwmHistory = [];
  static const int pwmHistoryLength = 50; // 表示用に長めに保持

  Future<void> sendDataToHeatables(List<int> data) async {
    try {
      final writeManager = heatablesDevice.getCapability<BleGattManager>();
      final deviceId = heatablesDevice.deviceId;

      final serviceUuid = _serviceUuid.toLowerCase();
      final characteristicUuid = _characteristicUuid.toLowerCase();

      debugPrint('writeManager: $writeManager');
      debugPrint(
          'Device ID: $deviceId, Service UUID: $serviceUuid, Characteristic UUID: $characteristicUuid');
      debugPrint('Data to send: $data');

      if (writeManager != null) {
        try {
          await writeManager.write(
            deviceId: deviceId,
            serviceId: serviceUuid,
            characteristicId: characteristicUuid,
            byteData: data,
          );
        } catch (e) {
          debugPrint('Send data error: $e');
        }
      }
    } catch (e) {
      debugPrint('Error in sendDataToHeatables: $e');
    }
  }

  void _initializePipeline() {
    final configProvider =
        Provider.of<SensorConfigurationProvider>(context, listen: false);
    _sensorConfigProvider = configProvider;
    final ppgSensor = widget.ppgSensor;
    final accelerometerSensor = widget.accelerometerSensor;
    final opticalTemperatureSensor = widget.opticalTemperatureSensor;
    final connectedWearables = widget.connectedDevices;

    final sampleFreq = _configureSensorForStreaming(
      ppgSensor,
      configProvider,
      fallbackFrequency: 50.0,
      targetFrequencyHz: 50,
    );
    if (accelerometerSensor != null) {
      _configureSensorForStreaming(
        accelerometerSensor,
        configProvider,
        fallbackFrequency: 50.0,
        targetFrequencyHz: 50,
      );
    }

    for (final wearable in connectedWearables) {
      debugPrint('Connected wearable device name: ${wearable.name}');
    }

    debugPrint(
        'opticalTemperatureSensor is ${opticalTemperatureSensor == null ? "null" : "not null"}');

    if (opticalTemperatureSensor != null) {
      _configureSensorForStreaming(
        opticalTemperatureSensor,
        configProvider,
        fallbackFrequency: 5.0,
        targetFrequencyHz: 5,
      );
    }

    final ppgStream = ppgSensor.sensorStream
        .map<PpgOpticalSample?>((data) {
          final values = _sensorValuesAsDoubles(data);
          if (values == null) {
            return null;
          }
          return _extractPpgOpticalSample(ppgSensor, data, values);
        })
        .where((sample) => sample != null)
        .cast<PpgOpticalSample>()
        .asBroadcastStream();

    Stream<PpgMotionSample>? accelerometerMotionStream;
    if (accelerometerSensor != null) {
      accelerometerMotionStream = accelerometerSensor.sensorStream
          .map<PpgMotionSample?>((data) {
            final values = _sensorValuesAsDoubles(data);
            if (values == null) {
              return null;
            }
            return _extractImuMotionSample(
              accelerometerSensor,
              data,
              values,
            );
          })
          .where((sample) => sample != null)
          .cast<PpgMotionSample>()
          .asBroadcastStream();
    }

    Stream<PpgTemperatureSample>? opticalTemperatureStream;
    if (opticalTemperatureSensor != null) {
      opticalTemperatureStream = opticalTemperatureSensor.sensorStream
          .map<PpgTemperatureSample?>((data) {
            final values = _sensorValuesAsDoubles(data);
            if (values == null) {
              return null;
            }
            return _extractOpticalTemperatureSample(
              opticalTemperatureSensor,
              data,
              values,
            );
          })
          .where((sample) => sample != null)
          .cast<PpgTemperatureSample>()
          .asBroadcastStream();
    }

    final ppgFilter = PpgFilter(
      inputStream: ppgStream,
      motionStream: accelerometerMotionStream,
      opticalTemperatureStream: opticalTemperatureStream,
      sampleFreq: sampleFreq,
      timestampExponent: ppgSensor.timestampExponent,
    );

    ppgFilter.initialize();
    if (!mounted) {
      ppgFilter.dispose();
      return;
    }
    setState(() {
      _displayPpgSignalStream = ppgFilter.displaySignalStream;
      _heartRateStream = ppgFilter.heartRateStream;
      _hrvStream = ppgFilter.hrvStream;
      _hrvLfhfStream = ppgFilter.hrvLfhfStream;
      _temperatureStream = ppgFilter.temperatureStream;
      _signalQualityStream = ppgFilter.signalQualityStream;
      _ppgFilter = ppgFilter;
    });
  }

  double _configureSensorForStreaming(
    Sensor sensor,
    SensorConfigurationProvider configProvider, {
    required double fallbackFrequency,
    required int targetFrequencyHz,
  }) {
    final configuration = sensor.relatedConfigurations.firstOrNull;
    if (configuration == null) {
      return fallbackFrequency;
    }

    if (configuration is ConfigurableSensorConfiguration &&
        configuration.availableOptions.contains(StreamSensorConfigOption())) {
      configProvider.addSensorConfigurationOption(
        configuration,
        StreamSensorConfigOption(),
        markPending: false,
      );
    }

    final values = configProvider.getSensorConfigurationValues(
      configuration,
      distinct: true,
    );
    SensorConfigurationValue? appliedValue;
    if (values.isNotEmpty) {
      appliedValue = _selectBestConfigurationValue(
        values,
        targetFrequencyHz: targetFrequencyHz,
      );
      configProvider.addSensorConfiguration(
        configuration,
        appliedValue,
        markPending: false,
      );
    }

    final selectedValue =
        configProvider.getSelectedConfigurationValue(configuration) ??
            appliedValue;
    if (selectedValue != null) {
      configuration.setConfiguration(selectedValue);
    }

    if (selectedValue is SensorFrequencyConfigurationValue) {
      return selectedValue.frequencyHz;
    }

    return fallbackFrequency;
  }

  SensorConfigurationValue _selectBestConfigurationValue(
    List<SensorConfigurationValue> values, {
    required int targetFrequencyHz,
  }) {
    final frequencyValues =
        values.whereType<SensorFrequencyConfigurationValue>().toList();
    if (frequencyValues.isEmpty) {
      return values.first;
    }

    SensorFrequencyConfigurationValue? nextBigger;
    SensorFrequencyConfigurationValue? maxValue;
    for (final value in frequencyValues) {
      if (maxValue == null || value.frequencyHz > maxValue.frequencyHz) {
        maxValue = value;
      }
      if (value.frequencyHz >= targetFrequencyHz &&
          (nextBigger == null || value.frequencyHz < nextBigger.frequencyHz)) {
        nextBigger = value;
      }
    }

    return nextBigger ?? maxValue ?? values.first;
  }

  List<double>? _sensorValuesAsDoubles(SensorValue data) {
    if (data is SensorDoubleValue) {
      return data.values;
    }
    if (data is SensorIntValue) {
      return data.values
          .map((value) => value.toDouble())
          .toList(growable: false);
    }
    return null;
  }

  PpgOpticalSample? _extractPpgOpticalSample(
    Sensor sensor,
    SensorValue data,
    List<double> values,
  ) {
    if (values.isEmpty) {
      return null;
    }

    int? findAxisIndex(List<String> keywords) {
      for (var i = 0; i < sensor.axisNames.length; i++) {
        final axis = sensor.axisNames[i].toLowerCase();
        if (keywords.any(axis.contains)) {
          return i;
        }
      }
      return null;
    }

    double valueAt(int? index, double fallback) {
      if (index != null && index >= 0 && index < values.length) {
        return values[index];
      }
      return fallback;
    }

    final fallbackRed = values[0];
    final fallbackIr = values.length > 1 ? values[1] : fallbackRed;
    final fallbackGreen = values.length > 2 ? values[2] : fallbackRed;
    final fallbackAmbient = values.length > 3 ? values[3] : 0.0;

    // Usually channels are [red, ir, green, ambient], but we prefer axis-name
    // matching when available to avoid firmware-order mismatches.
    final red = valueAt(findAxisIndex(['red']), fallbackRed);
    final ir = valueAt(findAxisIndex(['ir', 'infrared']), fallbackIr);
    final green = valueAt(findAxisIndex(['green']), fallbackGreen);
    final ambient = valueAt(findAxisIndex(['ambient']), fallbackAmbient);

    return PpgOpticalSample(
      timestamp: data.timestamp,
      red: red,
      ir: ir,
      green: green,
      ambient: ambient,
    );
  }

  PpgMotionSample _extractImuMotionSample(
    Sensor sensor,
    SensorValue data,
    List<double> values,
  ) {
    int? findAxisIndex(List<String> keywords) {
      for (var i = 0; i < sensor.axisNames.length; i++) {
        final axis = sensor.axisNames[i].toLowerCase();
        if (keywords.any(axis.contains)) {
          return i;
        }
      }
      return null;
    }

    double valueAt(int? index, double fallback) {
      if (index != null && index >= 0 && index < values.length) {
        return values[index];
      }
      return fallback;
    }

    final fallbackX = values.isNotEmpty ? values[0] : 0.0;
    final fallbackY = values.length > 1 ? values[1] : 0.0;
    final fallbackZ = values.length > 2 ? values[2] : 0.0;

    final x = valueAt(findAxisIndex(['x']), fallbackX);
    final y = valueAt(findAxisIndex(['y']), fallbackY);
    final z = valueAt(findAxisIndex(['z']), fallbackZ);

    return PpgMotionSample(
      timestamp: data.timestamp,
      x: x,
      y: y,
      z: z,
    );
  }

  PpgTemperatureSample? _extractOpticalTemperatureSample(
    Sensor sensor,
    SensorValue data,
    List<double> values,
  ) {
    //debugPrint('Extracting temperature sample data $data and values $values');
    if (values.isEmpty) {
      return null;
    }

    int? findAxisIndex(List<String> keywords) {
      for (var i = 0; i < sensor.axisNames.length; i++) {
        final axis = sensor.axisNames[i].toLowerCase();
        if (keywords.any(axis.contains)) {
          return i;
        }
      }
      return null;
    }

    final axisIndex = findAxisIndex(['temp', 'temperature']) ?? 0;
    if (axisIndex < 0 || axisIndex >= values.length) {
      return null;
    }
    final celsius = values[axisIndex];
    if (!celsius.isFinite) {
      return null;
    }
    return PpgTemperatureSample(
      timestamp: data.timestamp,
      celsius: celsius,
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayPpgSignalStream = _displayPpgSignalStream;
    final heartRateStream = _heartRateStream;
    final hrvStream = _hrvStream;
    final hrvLfhfStream = _hrvLfhfStream;
    final temperatureStream = _temperatureStream;
    final signalQualityStream = _signalQualityStream;

    return PlatformScaffold(
      appBar: PlatformAppBar(
        title: PlatformText('Heatables Demo'),
      ),
      body: displayPpgSignalStream == null ||
              heartRateStream == null ||
              hrvStream == null ||
              hrvLfhfStream == null ||
              temperatureStream == null ||
              signalQualityStream == null
          ? const Center(child: PlatformCircularProgressIndicator())
          : _buildContent(
              context,
              displayPpgSignalStream,
              heartRateStream,
              hrvStream,
              hrvLfhfStream,
              temperatureStream,
              signalQualityStream,
            ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    Stream<(int, double)> displayPpgSignalStream,
    Stream<double?> heartRateStream,
    Stream<double?> hrvStream,
    Stream<double?> hrvLfhfStream,
    Stream<double?> temperatureStream,
    Stream<PpgSignalQuality> signalQualityStream,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      children: [
        DeviceRow(
          group: WearableDisplayGroup.single(wearable: widget.wearable),
        ),
        const SizedBox(height: 12),
        StreamBuilder<PpgSignalQuality>(
          stream: signalQualityStream,
          builder: (context, qualitySnapshot) {
            final quality =
                qualitySnapshot.data ?? PpgSignalQuality.unavailable;
            final isEquipmentOn = quality != PpgSignalQuality.unavailable;
            return StreamBuilder<PpgSignalQuality>(
              stream: signalQualityStream,
              initialData: PpgSignalQuality.unavailable,
              builder: (context, qualitySnapshot) {
                final quality =
                    qualitySnapshot.data ?? PpgSignalQuality.unavailable;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 体温表示（既存の_MetricCardを利用）
                    Expanded(
                      child: _MetricCard(
                        title: 'Equipment',
                        icon: Icons.power_settings_new_rounded,
                        value: isEquipmentOn ? 'ON' : 'OFF',
                        unit: '',
                      ),
                    ),
                    const SizedBox(width: 12),
                    // 信号品質表示に_SignalQualityCardを利用
                    SizedBox(
                      width: 225, // 適宜調整してください
                      child: _SignalQualityCard(quality: quality),
                    ),
                  ],
                );
              },
            );
          },
        ),
        const SizedBox(height: 12),
        StreamBuilder<double?>(
          stream: heartRateStream,
          builder: (context, snapshot) {
            final bpm = snapshot.data;
            if (bpm != null && bpm.isFinite) {
              heartRateHistory.add(bpm);
              if (heartRateHistory.length > maxHistoryLength) {
                heartRateHistory.removeAt(0);
              }
            }

            return StreamBuilder<double?>(
              stream: hrvLfhfStream,
              builder: (context, hrvSnapshot) {
                final hrv = hrvSnapshot.data;
                if (hrv != null && hrv.isFinite) {
                  hrvHistory.add(hrv);
                  if (hrvHistory.length > maxHistoryLength) {
                    hrvHistory.removeAt(0);
                  }
                }
                final avgHrv = hrvHistory.isNotEmpty
                    ? (hrvHistory.reduce((a, b) => a + b) / hrvHistory.length)
                    : null;

                return Row(
                  children: [
                    Expanded(
                      child: _MetricCard(
                        title: 'Heart Rate',
                        icon: Icons.favorite_rounded,
                        value: bpm != null && bpm.isFinite
                            ? bpm.toStringAsFixed(0)
                            : '--',
                        unit: 'BPM',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _MetricCard(
                        title: 'LF/HF Ratio',
                        icon: Icons.bar_chart_rounded,
                        value:
                            avgHrv != null ? avgHrv.toStringAsFixed(1) : '--',
                        unit: '',
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
        const SizedBox(height: 12),
        _SignalPanelCard(
          title: 'Filtered PPG',
          subtitle: 'Live PPG with a basic pulse-band band-pass filter '
              '(0.5-3.2 Hz).',
          icon: Icons.show_chart_rounded,
          chartStream: displayPpgSignalStream,
          timestampExponent: widget.ppgSensor.timestampExponent,
          fixedMeasureMin: null,
          fixedMeasureMax: null,
        ),
        //_buildScanSection(),
        const SizedBox(height: 24), // 少し余白
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Heatables Control',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => _onModeChanged(ControlMode.manual),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _controlMode == ControlMode.manual
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        child: const Text('Manual'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => _onModeChanged(ControlMode.autopilot),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _controlMode == ControlMode.autopilot
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        child: const Text('Autopilot'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_controlMode == ControlMode.manual) ...[
                  Slider(
                    value: heatablesSliderValue.toDouble(),
                    min: 0,
                    max: 255,
                    divisions: 255,
                    label: heatablesSliderValue.toString(),
                    onChanged: (double value) {
                      setState(() {
                        heatablesSliderValue = value.round();
                      });
                      sendDataToHeatables([heatablesSliderValue]);
                    },
                  ),
                  Text('Value: $heatablesSliderValue'),
                ] else ...[
                  Text('Autopilot mode active. PWM controlled by heart rate.'),
                  Text('Current PWM: $heatablesSliderValue'),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final String value;
  final String unit;

  const _MetricCard({
    required this.title,
    required this.icon,
    required this.value,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    unit,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SignalPanelCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Stream<(int, double)> chartStream;
  final int timestampExponent;
  final double? fixedMeasureMin;
  final double? fixedMeasureMax;

  const _SignalPanelCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.chartStream,
    required this.timestampExponent,
    this.fixedMeasureMin,
    this.fixedMeasureMax,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 88,
              child: RollingChart(
                dataSteam: chartStream,
                timestampExponent: timestampExponent,
                timeWindow: 5,
                showXAxis: false,
                showYAxis: false,
                fixedMeasureMin: fixedMeasureMin,
                fixedMeasureMax: fixedMeasureMax,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SignalQualityCard extends StatelessWidget {
  final PpgSignalQuality quality;

  const _SignalQualityCard({
    required this.quality,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (label, hint, icon, color) = _presentQuality(colorScheme);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      icon,
                      size: 18,
                      color: color,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'PPG Signal',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ],
                ),
                Container(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  (String, String, IconData, Color) _presentQuality(ColorScheme colors) {
    switch (quality) {
      case PpgSignalQuality.unavailable:
        return (
          'Unavailable',
          'No stable heartbeat waveform yet.',
          Icons.portable_wifi_off_rounded,
          colors.onSurfaceVariant,
        );
      case PpgSignalQuality.bad:
        return (
          'Bad',
          'Signal is noisy.',
          Icons.signal_cellular_connected_no_internet_4_bar_rounded,
          colors.error,
        );
      case PpgSignalQuality.fair:
        return (
          'Fair',
          'Heartbeat is partially visible.',
          Icons.network_check_rounded,
          Colors.orange.shade700,
        );
      case PpgSignalQuality.good:
        return (
          'Good',
          'Signal quality is good.',
          Icons.check_circle_rounded,
          Colors.green.shade700,
        );
    }
  }
}
