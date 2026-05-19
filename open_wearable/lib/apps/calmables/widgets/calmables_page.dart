import 'dart:async';
//import 'dart:convert';
//import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';

//import 'package:universal_ble/universal_ble.dart';

import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:open_wearable/apps/calmables/model/ppg_filter.dart';
import 'package:open_wearable/apps/calmables/model/sensor_data_logger.dart';
import 'package:open_wearable/apps/calmables/model/hr_calibration.dart';
import 'package:open_wearable/apps/calmables/widgets/calmables_card_styles.dart';
import 'package:open_wearable/apps/calmables/widgets/rowling_chart.dart';
import 'package:open_wearable/apps/calmables/widgets/rolling_hr_chart.dart';
import 'package:open_wearable/apps/calmables/widgets/study_protocol_page.dart';
import 'package:open_wearable/models/wearable_display_group.dart';
import 'package:open_wearable/view_models/sensor_configuration_provider.dart';
import 'package:open_wearable/view_models/wearables_provider.dart';
import 'package:open_wearable/widgets/devices/devices_page.dart';
import 'package:provider/provider.dart';

class CalmablesPage extends StatefulWidget {
  final Wearable wearable;
  final Sensor ppgSensor;
  final Sensor? opticalTemperatureSensor;
  final Sensor? accelerometerSensor;
  final List<Wearable> connectedDevices;

  const CalmablesPage({
    super.key,
    required this.wearable,
    required this.ppgSensor,
    this.opticalTemperatureSensor,
    this.accelerometerSensor,
    this.connectedDevices = const [],
  });

  @override
  State<CalmablesPage> createState() => _CalmablesPageState();
}

enum ControlMode { manual, autopilot }

class _CalmablesPageState extends State<CalmablesPage> {
  PpgFilter? _ppgFilter;
  Stream<(int, double)>? _displayPpgSignalStream;
  Stream<List<int>>? _peakTimestampsStream;
  Stream<(int, double)>? _rawHrChartStream;
  Stream<(int, double)>? _smoothedHrChartStream;

  Stream<double?>? _heartRateStream;
  Stream<double?>? _hrvStream;
  Stream<double?>? _hrvLfhfStream;
  Stream<double?>? _temperatureStream;
  Stream<PpgSignalQuality>? _signalQualityStream;
  SensorConfigurationProvider? _sensorConfigProvider;

  //final WearableManager _wearableManager = WearableManager();
  ControlMode _controlMode = ControlMode.manual;
  StreamSubscription<double?>? _heartRateSubscription;

  final SensorDataLogger _dataLogger = SensorDataLogger();
  final HrCalibration _calibration = HrCalibration();
  Timer? _calibrationUiTimer;
  Stream<PpgOpticalSample>? _rawPpgStream;
  Stream<PpgMotionSample>? _rawImuStream;

  // Manual baseline/trigger overrides
  final TextEditingController _baselineController = TextEditingController();
  final TextEditingController _triggerController = TextEditingController();

  Wearable? calmablesDevice;

  int calmablesSliderValue = 0;
  bool _manualPwmOn = false;
  bool _autopilotActive = false;
  VoidCallback? _sheetRefresh;

  double BoxWidth = 186;
  double BoxHeight = 120;

  final String _characteristicUuid = "6bb7da44-e8b9-3e3f-6d5a-e212c378d2df";
  final String _serviceUuid = "a542957a-968b-91fa-254c-62c7a367a692";

  List<double> heartRateHistory = [];
  static const int maxHistoryLength = 5;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      calmablesDevice = widget.connectedDevices.cast<Wearable?>().firstWhere(
            (device) => device!.name.toLowerCase().contains('calmables'),
            orElse: () => null,
          );

      _initializePipeline();
    });

    //startOpenEarableScan();
  }

  @override
  void dispose() {
    final configProvider = _sensorConfigProvider;
    _heartRateSubscription?.cancel();
    if (_dataLogger.isLogging) {
      _dataLogger.stop();
    }
    _calibration.stop();
    _calibrationUiTimer?.cancel();
    _baselineController.dispose();
    _triggerController.dispose();
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
      _manualPwmOn = false;
      _autopilotActive = false;
      pwmHistory.clear();
    });
    sendDataToCalmables([0]);

    if (mode == ControlMode.autopilot) {
      // HR threshold-based control
      _heartRateSubscription = _heartRateStream?.listen((bpm) {
        if (bpm == null || !bpm.isFinite) return;
        final result = _calibration.latestResult;
        if (result == null) return;

        final trigger = result.triggerThreshold;
        final baseline = result.baselineHeartRate;
        final deactivateThreshold = (trigger - baseline) * 0.2 + baseline;

        final bool activate;
        if (bpm > trigger) {
          activate = true;
        } else if (bpm < deactivateThreshold) {
          activate = false;
        } else {
          return; // hysteresis zone – keep current state
        }

        if (activate != _autopilotActive) {
          final pwm = activate ? calmablesSliderValue : 0;
          sendDataToCalmables([pwm]);
          setState(() {
            _autopilotActive = activate;
            pwmHistory.add(pwm);
            if (pwmHistory.length > pwmHistoryLength) {
              pwmHistory.removeAt(0);
            }
          });
        }
      });
    } else {
      // Manual mode – cancel HR subscription
      _heartRateSubscription?.cancel();
      _heartRateSubscription = null;
    }
  }

  List<int> pwmHistory = [];
  static const int pwmHistoryLength = 50;

  Future<bool> sendDataToCalmables(List<int> data) async {
    final device = calmablesDevice;
    if (device == null) {
      debugPrint('No Calmables device connected, skipping BLE write.');
      return false;
    }
    try {
      final writeManager = device.getCapability<BleGattManager>();
      final deviceId = device.deviceId;

      final serviceUuid = _serviceUuid.toLowerCase();
      final characteristicUuid = _characteristicUuid.toLowerCase();

      debugPrint('writeManager: $writeManager');
      debugPrint(
        'Device ID: $deviceId, Service UUID: $serviceUuid, Characteristic UUID: $characteristicUuid',
      );
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
      debugPrint('Error in sendDataToCalmables: $e');
    }
    return true;
  }

  /// Tries to find a Calmables wearable in the live WearablesProvider.
  /// If not immediately available, waits up to [_kCalmablesSearchTimeout] for
  /// the auto-connector to establish the BLE connection, showing a loading
  /// dialog in the meantime.
  /// Returns true if Calmables is (now) available.
  static const Duration _kCalmablesSearchTimeout = Duration(seconds: 30);

  Future<bool> _ensureCalmablesConnected() async {
    if (calmablesDevice != null) return true;
    if (!mounted) return false;

    final provider = Provider.of<WearablesProvider>(context, listen: false);

    Wearable? _findInProvider() =>
        provider.wearables.cast<Wearable?>().firstWhere(
              (w) => w!.name.toLowerCase().contains('calmables'),
              orElse: () => null,
            );

    // Fast path: already in provider list
    final existing = _findInProvider();
    if (existing != null) {
      setState(() => calmablesDevice = existing);
      debugPrint('Calmables found immediately: ${existing.name}');
      return true;
    }

    // Slow path: wait for auto-connector to connect the device
    if (!mounted) return false;
    final completer = Completer<bool>();

    void listener() {
      if (completer.isCompleted) return;
      final found = _findInProvider();
      if (found != null) {
        if (mounted) setState(() => calmablesDevice = found);
        debugPrint('Calmables auto-connected: ${found.name}');
        completer.complete(true);
      }
    }

    provider.addListener(listener);

    // Show loading dialog while waiting
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('Searching for Calmables…')),
          ],
        ),
      ),
    );

    // Timeout
    Future.delayed(_kCalmablesSearchTimeout, () {
      if (!completer.isCompleted) completer.complete(false);
    });

    final result = await completer.future;
    provider.removeListener(listener);

    // Dismiss loading dialog
    if (mounted) Navigator.of(context, rootNavigator: true).pop();

    return result;
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
      'opticalTemperatureSensor is ${opticalTemperatureSensor == null ? "null" : "not null"}',
    );

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
      _peakTimestampsStream = ppgFilter.peakTimestampsStream;
      _rawHrChartStream = ppgFilter.rawHeartRateChartStream;
      _smoothedHrChartStream = ppgFilter.smoothedHeartRateChartStream;
      _heartRateStream = ppgFilter.heartRateStream;
      _hrvStream = ppgFilter.hrvStream;
      _hrvLfhfStream = ppgFilter.hrvLfhfStream;
      _temperatureStream = ppgFilter.temperatureStream;
      _signalQualityStream = ppgFilter.signalQualityStream;
      _ppgFilter = ppgFilter;
      _rawPpgStream = ppgStream;
      _rawImuStream = accelerometerMotionStream;
    });

    // Show live partial results during calibration.
    _calibration.onResultUpdated = (_) {
      if (mounted) setState(() {});
    };
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

  Future<void> _onStartRecordingPressed() async {
    final ppgStream = _rawPpgStream;
    if (ppgStream == null) return;

    final useProtocol = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start Recording'),
        content: const Text('Record with study protocol?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No – Standard'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF009682),
              foregroundColor: Colors.white,
            ),
            child: const Text('Yes – With Protocol'),
          ),
        ],
      ),
    );
    if (useProtocol == null || !mounted) return;

    if (!useProtocol) {
      await _dataLogger.start(
        ppgStream: ppgStream,
        imuStream: _rawImuStream,
        heartRateStream: _heartRateStream,
        lfhfStream: _hrvLfhfStream,
      );
      if (mounted) setState(() {});
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => StudyProtocolPage(
            dataLogger: _dataLogger,
            ppgStream: ppgStream,
            imuStream: _rawImuStream,
            heartRateStream: _heartRateStream,
            lfhfStream: _hrvLfhfStream,
            displayPpgStream: _displayPpgSignalStream,
            rawHrStream: _rawHrChartStream,
            smoothedHrStream: _smoothedHrChartStream,
            timestampExponent: widget.ppgSensor.timestampExponent,
            signalQualityStream: _signalQualityStream,
            onSendToCalmables: sendDataToCalmables,
            onConnectCalmables: _ensureCalmablesConnected,
          ),
        ),
      );
      if (mounted) setState(() {});
    }
  }

  Widget _buildModeTab(BuildContext context, String label, ControlMode mode) {
    final active = _controlMode == mode;
    final isHrMode = mode == ControlMode.autopilot;
    final hasCalibration = _calibration.latestResult != null;
    final disabled = isHrMode && !hasCalibration;
    return Expanded(
      child: GestureDetector(
        onTap: disabled ? null : () => _onModeChanged(mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF009682) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: disabled
                  ? Colors.grey.shade400
                  : (active ? Colors.white : Colors.grey.shade700),
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  void _openCalibrationSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (_, setSheetState) {
          _sheetRefresh = () => setSheetState(() {});
          _calibration.onResultUpdated = (_) {
            if (mounted) setState(() {});
            _sheetRefresh?.call();
          };

          final result = _calibration.latestResult;
          final isCalibrating = _calibration.isCalibrating;

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 24,
              left: 20,
              right: 20,
              top: 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(
                      Icons.tune_rounded,
                      size: 20,
                      color: isCalibrating
                          ? Colors.orange
                          : const Color(0xFF009682),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Calibration',
                      style: Theme.of(sheetCtx)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (isCalibrating) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _calibration.progressFraction,
                      minHeight: 6,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFF009682)),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${_calibration.elapsedSeconds.toStringAsFixed(0)} / '
                    '${HrCalibration.calibrationDuration.inSeconds} s',
                    style: Theme.of(sheetCtx)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 16),
                ],
                Row(
                  children: [
                    Expanded(
                      child: _EditableMetricField(
                        label: 'Baseline (BPM)',
                        controller: _baselineController,
                        hintValue: result != null
                            ? result.baselineHeartRate.toStringAsFixed(1)
                            : '--',
                        onSubmitted: (val) {
                          final parsed = double.tryParse(val);
                          if (parsed != null) {
                            final r = _calibration.latestResult;
                            if (r != null) {
                              r.baselineHeartRate = parsed;
                            } else {
                              _calibration.setManualResult(
                                baseline: parsed,
                                trigger:
                                    double.tryParse(_triggerController.text) ??
                                        parsed + 10,
                              );
                            }
                            setSheetState(() {});
                            setState(() {});
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _EditableMetricField(
                        label: 'Trigger (BPM)',
                        controller: _triggerController,
                        hintValue: result != null
                            ? result.triggerThreshold.toStringAsFixed(1)
                            : '--',
                        onSubmitted: (val) {
                          final parsed = double.tryParse(val);
                          if (parsed != null) {
                            final r = _calibration.latestResult;
                            if (r != null) {
                              r.triggerThreshold = parsed;
                            } else {
                              _calibration.setManualResult(
                                baseline:
                                    double.tryParse(_baselineController.text) ??
                                        parsed - 10,
                                trigger: parsed,
                              );
                            }
                            setSheetState(() {});
                            setState(() {});
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: isCalibrating
                        ? () {
                            _calibration.stop();
                            _calibrationUiTimer?.cancel();
                            _calibrationUiTimer = null;
                            setSheetState(() {});
                            setState(() {});
                          }
                        : () {
                            final hrStream = _heartRateStream;
                            final qualityStream = _signalQualityStream;
                            if (hrStream == null || qualityStream == null) {
                              return;
                            }
                            _calibration.onResultUpdated = (_) {
                              if (mounted) setState(() {});
                              _sheetRefresh?.call();
                            };
                            _calibration.onCalibrationFinished = () {
                              _calibrationUiTimer?.cancel();
                              _calibrationUiTimer = null;
                              if (mounted) setState(() {});
                              _sheetRefresh?.call();
                            };
                            _calibration.start(
                              heartRateStream: hrStream,
                              signalQualityStream: qualityStream,
                            );
                            _calibrationUiTimer?.cancel();
                            _calibrationUiTimer = Timer.periodic(
                              const Duration(milliseconds: 500),
                              (_) {
                                if (mounted) setState(() {});
                                _sheetRefresh?.call();
                              },
                            );
                            setSheetState(() {});
                          },
                    icon: Icon(
                      isCalibrating
                          ? Icons.stop_rounded
                          : Icons.play_arrow_rounded,
                      size: 18,
                    ),
                    label: Text(
                      isCalibrating ? 'Stop' : 'Start Calibration',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isCalibrating
                          ? Colors.orange
                          : const Color(0xFF009682),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ).whenComplete(() {
      _sheetRefresh = null;
      _calibration.onResultUpdated = (_) {
        if (mounted) setState(() {});
      };
    });
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
        title: PlatformText('Calmables Demo'),
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
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        StreamBuilder<PpgSignalQuality>(
          stream: signalQualityStream,
          initialData: PpgSignalQuality.unavailable,
          builder: (context, qualitySnapshot) {
            final quality =
                qualitySnapshot.data ?? PpgSignalQuality.unavailable;
            return StreamBuilder<double?>(
              stream: heartRateStream,
              builder: (context, hrSnapshot) {
                final bpm = hrSnapshot.data;
                if (bpm != null && bpm.isFinite) {
                  heartRateHistory.add(bpm);
                  if (heartRateHistory.length > maxHistoryLength) {
                    heartRateHistory.removeAt(0);
                  }
                }
                return Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: BoxHeight,
                            child: _SignalQualityCard(quality: quality),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: SizedBox(
                            height: BoxHeight,
                            child: _MetricCard(
                              title: 'Heart Rate',
                              icon: Icons.favorite_rounded,
                              value: bpm != null && bpm.isFinite
                                  ? bpm.toStringAsFixed(0)
                                  : '--',
                              unit: 'BPM',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: BoxHeight,
                            child: _MetricCard(
                              title: 'Baseline',
                              icon: Icons.horizontal_rule_rounded,
                              value: _calibration.latestResult != null
                                  ? _calibration.latestResult!.baselineHeartRate
                                      .toStringAsFixed(1)
                                  : '--',
                              unit: 'BPM',
                              onTap: _openCalibrationSheet,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: SizedBox(
                            height: BoxHeight,
                            child: _MetricCard(
                              title: 'Trigger',
                              icon: Icons.arrow_upward_rounded,
                              value: _calibration.latestResult != null
                                  ? _calibration.latestResult!.triggerThreshold
                                      .toStringAsFixed(1)
                                  : '--',
                              unit: 'BPM',
                              onTap: _openCalibrationSheet,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            );
          },
        ),
        const SizedBox(height: 14),
        _SignalPanelCard(
          title: 'PPG Signal',
          subtitle: '',
          icon: Icons.show_chart_rounded,
          chartStream: displayPpgSignalStream,
          peakTimestampsStream: _peakTimestampsStream,
          timestampExponent: widget.ppgSensor.timestampExponent,
          fixedMeasureMin: null,
          fixedMeasureMax: null,
        ),
        const SizedBox(height: 14),
        if (_rawHrChartStream != null && _smoothedHrChartStream != null)
          CalmablesCardShell(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CalmablesCardHeader(
                  icon: Icons.favorite_rounded,
                  title: 'Heart Rate (60s)',
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 120,
                  child: RollingHrChart(
                    rawHrStream: _rawHrChartStream!,
                    smoothedHrStream: _smoothedHrChartStream!,
                    timestampExponent: widget.ppgSensor.timestampExponent,
                    timeWindow: 60,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 14),
        CalmablesCardShell(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CalmablesCardHeader(
                icon: Icons.tune_rounded,
                title: 'Control',
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.all(3),
                child: Row(
                  children: [
                    _buildModeTab(context, 'Manual', ControlMode.manual),
                    _buildModeTab(context, 'HR-based', ControlMode.autopilot),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (_controlMode == ControlMode.manual) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Heat Output',
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w500),
                    ),
                    Row(
                      children: [
                        Text(
                          _manualPwmOn ? 'ON' : 'OFF',
                          style: TextStyle(
                            color: _manualPwmOn
                                ? calmablesAccentColor
                                : Colors.grey.shade400,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Switch(
                          value: _manualPwmOn,
                          activeColor: calmablesAccentColor,
                          activeTrackColor:
                              calmablesAccentColor.withOpacity(0.3),
                          trackOutlineColor: WidgetStateProperty.resolveWith(
                            (states) => states.contains(WidgetState.selected)
                                ? calmablesAccentColor
                                : Colors.grey.shade300,
                          ),
                          onChanged: (v) {
                            setState(() => _manualPwmOn = v);
                            sendDataToCalmables([v ? calmablesSliderValue : 0]);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Intensity',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: Colors.grey.shade600),
                    ),
                    Text(
                      _warmthLabel(calmablesSliderValue),
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: _pwmColor(calmablesSliderValue),
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4.0,
                    trackShape: const _GradientSliderTrackShape(),
                    thumbColor: _pwmColor(calmablesSliderValue),
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    overlayColor:
                        _pwmColor(calmablesSliderValue).withOpacity(0.2),
                    showValueIndicator: ShowValueIndicator.onlyForDiscrete,
                    valueIndicatorColor: Colors.grey.shade700,
                    valueIndicatorTextStyle: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  child: Slider(
                    value: calmablesSliderValue.toDouble(),
                    min: 0,
                    max: 255,
                    divisions: 255,
                    label: calmablesSliderValue.toString(),
                    onChanged: (double value) {
                      setState(() {
                        calmablesSliderValue = value.round();
                      });
                      if (_manualPwmOn) {
                        sendDataToCalmables([calmablesSliderValue]);
                      }
                      _dataLogger.logMetrics(pwm: calmablesSliderValue);
                    },
                  ),
                ),
              ] else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Heat Output',
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w500),
                    ),
                    Row(
                      children: [
                        AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 300),
                          style: TextStyle(
                            color: _autopilotActive
                                ? const Color(0xFFFFB300)
                                : Colors.grey.shade400,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                          child: Text(_autopilotActive ? 'ACTIVE' : 'INACTIVE'),
                        ),
                        const SizedBox(width: 10),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 400),
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _autopilotActive
                                ? const Color(0xFFFFB300)
                                : Colors.grey.shade300,
                            boxShadow: _autopilotActive
                                ? [
                                    BoxShadow(
                                      color: const Color(0xFFFFB300)
                                          .withOpacity(0.7),
                                      blurRadius: 8,
                                      spreadRadius: 2,
                                    )
                                  ]
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Intensity',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: Colors.grey.shade600),
                    ),
                    Text(
                      _warmthLabel(calmablesSliderValue),
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: _pwmColor(calmablesSliderValue),
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4.0,
                    trackShape: const _GradientSliderTrackShape(),
                    thumbColor: _pwmColor(calmablesSliderValue),
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    overlayColor:
                        _pwmColor(calmablesSliderValue).withOpacity(0.2),
                    showValueIndicator: ShowValueIndicator.onlyForDiscrete,
                    valueIndicatorColor: Colors.grey.shade700,
                    valueIndicatorTextStyle: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  child: Slider(
                    value: calmablesSliderValue.toDouble(),
                    min: 0,
                    max: 255,
                    divisions: 255,
                    label: calmablesSliderValue.toString(),
                    onChanged: (double value) {
                      setState(() {
                        calmablesSliderValue = value.round();
                      });
                      if (_autopilotActive) {
                        sendDataToCalmables([calmablesSliderValue]);
                      }
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        DeviceRow(
          group: WearableDisplayGroup.single(wearable: widget.wearable),
        ),
      ],
    );
  }
}

// ── Colour helpers ─────────────────────────────────────────────────

Color _pwmColor(int pwm) {
  final t = (pwm / 255.0).clamp(0.0, 1.0);
  if (t <= 0.33) {
    return Color.lerp(
      const Color(0xFF2196F3), // blue
      const Color(0xFF4CAF50), // green
      t / 0.33,
    )!;
  }
  if (t <= 0.66) {
    return Color.lerp(
      const Color(0xFF4CAF50), // green
      const Color(0xFFFF9800), // orange
      (t - 0.33) / 0.33,
    )!;
  }
  return Color.lerp(
    const Color(0xFFFF9800), // orange
    const Color(0xFFF44336), // red
    (t - 0.66) / 0.34,
  )!;
}

String _warmthLabel(int pwm) {
  if (pwm == 0) return 'Off';
  if (pwm < 85) return 'Low Intensity';
  if (pwm < 170) return 'Medium Intensity';
  return 'High Intensity';
}

// ── Gradient slider track ───────────────────────────────────────────────────

class _GradientSliderTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  const _GradientSliderTrackShape();

  static const _gradientColors = [
    Color(0xFF2196F3), // blue
    Color(0xFF4CAF50), // green
    Color(0xFFFF9800), // orange
    Color(0xFFF44336), // red
  ];

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    const trackHeight = 4.0;
    final thumbWidth = (sliderTheme.thumbShape ?? const RoundSliderThumbShape())
        .getPreferredSize(isEnabled, isDiscrete)
        .width;
    final trackLeft = offset.dx + thumbWidth / 2;
    final trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    final trackRight = trackLeft + parentBox.size.width - thumbWidth;
    return Rect.fromLTRB(
        trackLeft, trackTop, trackRight, trackTop + trackHeight);
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    const radius = Radius.circular(4);
    final clampedThumb = thumbCenter.dx.clamp(trackRect.left, trackRect.right);

    // Full gray background track (always visible)
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, radius),
      Paint()..color = Colors.grey.shade300,
    );

    // Active (left) portion – gradient overlay
    if (clampedThumb > trackRect.left) {
      final activeRect = Rect.fromLTRB(
        trackRect.left,
        trackRect.top - additionalActiveTrackHeight / 2,
        clampedThumb,
        trackRect.bottom + additionalActiveTrackHeight / 2,
      );
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(activeRect, radius),
        Paint()
          ..shader = const LinearGradient(colors: _gradientColors)
              .createShader(trackRect),
      );
    }
  }
}

// ── Editable metric field ───────────────────────────────────────────────────

class _EditableMetricField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hintValue;
  final ValueChanged<String> onSubmitted;

  const _EditableMetricField({
    required this.label,
    required this.controller,
    required this.hintValue,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium,
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            hintText: hintValue,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: onSubmitted,
          onEditingComplete: () {
            onSubmitted(controller.text);
            FocusScope.of(context).unfocus();
          },
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
  final VoidCallback? onTap;

  const _MetricCard({
    required this.title,
    required this.icon,
    required this.value,
    required this.unit,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return CalmablesCardShell(
      onTap: onTap,
      padding: calmablesSmallCardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CalmablesCompactHeader(
            icon: icon,
            title: title,
            trailing: onTap == null
                ? null
                : Icon(
                    Icons.edit_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
          ),
          const SizedBox(height: 10),
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
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SignalPanelCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Stream<(int, double)> chartStream;
  final Stream<List<int>>? peakTimestampsStream;
  final int timestampExponent;
  final double? fixedMeasureMin;
  final double? fixedMeasureMax;

  const _SignalPanelCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.chartStream,
    this.peakTimestampsStream,
    required this.timestampExponent,
    this.fixedMeasureMin,
    this.fixedMeasureMax,
  });

  @override
  Widget build(BuildContext context) {
    return CalmablesCardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CalmablesCardHeader(
            icon: icon,
            title: title,
            subtitle: subtitle.isEmpty ? null : subtitle,
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 88,
            child: RollingChart(
              dataSteam: chartStream,
              peakTimestampsStream: peakTimestampsStream,
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
    final (label, _, icon, color) =
        _presentQuality(Theme.of(context).colorScheme);
    return CalmablesCardShell(
      padding: calmablesSmallCardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CalmablesCompactHeader(
            icon: icon,
            title: 'PPG',
            accentColor: color,
          ),
          const Spacer(),
          Align(
            alignment: Alignment.centerLeft,
            child: CalmablesStatusChip(
              label: label,
              color: color,
              dense: true,
              textStyle: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ],
      ),
    );
  }

  (String, String, IconData, Color) _presentQuality(ColorScheme colors) {
    switch (quality) {
      case PpgSignalQuality.unavailable:
        return (
          'Unavailable',
          'No stable heartbeat',
          Icons.portable_wifi_off_rounded,
          colors.onSurfaceVariant,
        );
      case PpgSignalQuality.bad:
        return (
          'Bad',
          'Signal is noisy',
          Icons.signal_cellular_connected_no_internet_4_bar_rounded,
          colors.error,
        );
      case PpgSignalQuality.fair:
        return (
          'Fair',
          'Heartbeat is visible',
          Icons.network_check_rounded,
          Colors.orange.shade700,
        );
      case PpgSignalQuality.good:
        return (
          'Good',
          'Signal quality is good',
          Icons.check_circle_rounded,
          Color(0xFF8CB63C),
        );
    }
  }
}
