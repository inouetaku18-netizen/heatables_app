import 'dart:async';
//import 'dart:convert';
//import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';

import 'package:universal_ble/universal_ble.dart';

import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:open_wearable/apps/heatables/model/ppg_filter.dart';
import 'package:open_wearable/apps/heatables/widgets/rowling_chart.dart';
import 'package:open_wearable/models/wearable_display_group.dart';
import 'package:open_wearable/view_models/sensor_configuration_provider.dart';
import 'package:open_wearable/widgets/devices/devices_page.dart';
import 'package:provider/provider.dart';

class HeatablesPage extends StatefulWidget {
  final Wearable wearable;
  final Sensor ppgSensor;
  final Sensor? opticalTemperatureSensor;
  final Sensor? accelerometerSensor;

  const HeatablesPage({
    super.key,
    required this.wearable,
    required this.ppgSensor,
    this.opticalTemperatureSensor,
    this.accelerometerSensor,
  });

  @override
  State<HeatablesPage> createState() => _HeatablesPageState();
}

class Notifier extends WearableDisconnectNotifier {
  // 状態とメソッドを定義
}

class _HeatablesPageState extends State<HeatablesPage> {
  PpgFilter? _ppgFilter;
  Stream<(int, double)>? _displayPpgSignalStream;
  Stream<double?>? _heartRateStream;
  Stream<double?>? _temperatureStream;
  Stream<PpgSignalQuality>? _signalQualityStream;
  SensorConfigurationProvider? _sensorConfigProvider;

  List<DiscoveredDevice> scannedDevices = [];
  final Map<String, Wearable> connectedWearables = {};

  final WearableManager _wearableManager = WearableManager();

  // ESP32(Heatables)用スライダー値（0-255）
  int heatablesSliderValue = 0;

  //心拍数の平均の表示
  List<double> heartRateHistory = [];
  static const int maxHistoryLength = 5;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _initializePipeline();
    });

    // WearableFactoryの登録例（必要に応じて拡張）
    _wearableManager.addWearableFactory(HeatablesFactory());

    startOpenEarableScan();
  }

  void startOpenEarableScan() async {
    await _wearableManager.startScan();
    _wearableManager.scanStream.listen((device) {
      if (device.name.isNotEmpty &&
          !scannedDevices.any((d) => d.id == device.id)) {
        setState(() {
          scannedDevices.add(device);
        });
      }
    });
  }

  Future<void> connectToOpenEarable(DiscoveredDevice device) async {
    final wearable = await _wearableManager.connectToDevice(device);
    final id = wearable.deviceId;
    connectedWearables[id] = wearable;

    setState(() {});
  }

  Future<void> disconnectOpenEarable(String deviceId) async {
    final wearable = connectedWearables[deviceId];
    if (wearable != null) {
      await wearable.disconnect();

      connectedWearables.remove(deviceId);
      setState(() {});
    }
  }

  Future<void> sendDataToHeatables(List<int> data) async {
    // HeatablesWearableを探して送信
    final heatables = connectedWearables.values
        .whereType<HeatablesWearable>()
        .firstWhere((_) => true);

    await heatables.sendData(data);
  }

  void _initializePipeline() {
    final configProvider =
        Provider.of<SensorConfigurationProvider>(context, listen: false);
    _sensorConfigProvider = configProvider;
    final ppgSensor = widget.ppgSensor;
    final accelerometerSensor = widget.accelerometerSensor;
    final opticalTemperatureSensor = widget.opticalTemperatureSensor;

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
      _temperatureStream = ppgFilter.temperatureStream;
      _signalQualityStream = ppgFilter.signalQualityStream;
      _ppgFilter = ppgFilter;
    });
  }

  @override
  void dispose() {
    final configProvider = _sensorConfigProvider;
    if (configProvider != null) {
      unawaited(configProvider.turnOffAllSensors());
    }
    _ppgFilter?.dispose();
    super.dispose();
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
    final temperatureStream = _temperatureStream;
    final signalQualityStream = _signalQualityStream;

    return PlatformScaffold(
      appBar: PlatformAppBar(
        title: PlatformText('Heatables Demo'),
      ),
      body: displayPpgSignalStream == null ||
              heartRateStream == null ||
              temperatureStream == null ||
              signalQualityStream == null
          ? const Center(child: PlatformCircularProgressIndicator())
          : _buildContent(
              context,
              displayPpgSignalStream,
              heartRateStream,
              temperatureStream,
              signalQualityStream,
            ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    Stream<(int, double)> displayPpgSignalStream,
    Stream<double?> heartRateStream,
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
        StreamBuilder<double?>(
          stream: temperatureStream,
          builder: (context, tempSnapshot) {
            final celsius = tempSnapshot.data;
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
                        title: 'Temp',
                        icon: Icons.thermostat_rounded,
                        value: celsius != null && celsius.isFinite
                            ? celsius.toStringAsFixed(1)
                            : '--',
                        unit: '°C',
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

            final avgBpm = heartRateHistory.isNotEmpty
                ? (heartRateHistory.reduce((a, b) => a + b) /
                    heartRateHistory.length)
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
                    title: 'Average Heart Rate',
                    icon: Icons.favorite_border_rounded,
                    value: avgBpm != null ? avgBpm.toStringAsFixed(0) : '--',
                    unit: 'BPM',
                  ),
                ),
              ],
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
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 13,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  'This view is for demonstration purposes only. It is not a medical device and must not be used for diagnosis, treatment, or emergency decisions.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// Heatablesデバイス（ESP32）用カスタムウェアラブル
class HeatablesWearable extends Wearable {
  final String _deviceId;
  // Characteristic UUID
  final String characteristicUuid = "6bb7da44-e8b9-3e3f-6d5a-e212c378d2df";
  final String serviceUuid = "a542957a-968b-91fa-254c-62c7a367a692";

  HeatablesWearable(String name, dynamic disconnectNotifier, this._deviceId)
      : super(name: name, disconnectNotifier: disconnectNotifier);

  @override
  Future<void> disconnect() async {
    // 切断処理
  }

  @override
  String get deviceId => _deviceId;

  // 書き込み用例。対象のControlManager等に応じて実装を調整
  Future<void> sendData(List<int> data) async {
    final writeManager = getCapability<BleGattManager>();
    if (writeManager != null) {
      try {
        // 例: ControlManagerのwriteCharacteristicで送信（要実装詳細に合わせ調整）
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
  }
}

// heatablesFactory
class HeatablesFactory extends WearableFactory {
  @override
  Future<bool> matches(
    DiscoveredDevice device,
    List<BleService> services,
  ) async {
    if (device.name.toLowerCase().contains('heatables')) {
      return true;
    }
    return false;
  }

  @override
  Future<Wearable> createFromDevice(
    DiscoveredDevice device, {
    Set<ConnectionOption> options = const {},
  }) async {
    if (bleManager == null) {
      throw Exception("BleGattManager is not initialized");
    }

    // Create and return an instance of your custom wearable
    String name = device.name;
    Notifier disconnectNotifier = Notifier();

    return HeatablesWearable(name, disconnectNotifier, device.id);
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
