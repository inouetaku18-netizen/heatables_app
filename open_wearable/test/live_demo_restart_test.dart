import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_wearable/apps/calmables/model/hr_calibration.dart';
import 'package:open_wearable/apps/calmables/model/ppg_filter.dart';
import 'package:open_wearable/apps/calmables/widgets/live_demo_page.dart';

/// "Start Again" must hand the next participant a fresh baseline measurement,
/// including a timer that counts from zero.
void main() {
  testWidgets('restarting the demo restarts the baseline measurement',
      (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final hr = StreamController<double?>.broadcast();
    final quality = StreamController<PpgSignalQuality>.broadcast();
    final raw = StreamController<(int, double)>.broadcast();
    final smoothed = StreamController<(int, double)>.broadcast();
    addTearDown(() {
      hr.close();
      quality.close();
      raw.close();
      smoothed.close();
    });

    // A pre-set baseline lets the run reach the summary without waiting for a
    // full 30 s measurement.
    final calibration = HrCalibration()
      ..setManualResult(baseline: 70, trigger: 85);

    await tester.pumpWidget(
      MaterialApp(
        home: LiveDemoPage(
          heartRateStream: hr.stream,
          signalQualityStream: quality.stream,
          rawHrStream: raw.stream,
          smoothedHrStream: smoothed.stream,
          timestampExponent: -3,
          calibration: calibration,
          hrSourceName: 'OpenEarable',
          isCalmablesConnected: () => true,
          onConnectCalmables: () async => true,
          onSendToCalmables: (_) async => true,
        ),
      ),
    );
    await tester.pump();

    Future<void> advance() async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    hr.add(72);
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Start Demo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Baseline measurement'), findsOneWidget);
    expect(calibration.isCalibrating, isFalse);

    // Run to the summary.
    await tester.tap(find.text('Continue'));
    await advance();
    for (var i = 0; i < 4; i++) {
      hr.add(95);
      await tester.pump(const Duration(milliseconds: 300));
    }
    await advance();
    await tester.pump(const Duration(seconds: 31));
    await tester.tap(find.text('End relaxation'));
    await advance();
    await tester.tap(find.text("I'm back"));
    await tester.pumpAndSettle();
    for (var statement = 0; statement < 2; statement++) {
      await tester.ensureVisible(find.text('Strongly Agree'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Strongly Agree'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Demo complete'), findsOneWidget);

    // Start Again → the next visit to the baseline screen must measure anew.
    await tester.tap(find.text('Start Again'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start Demo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Baseline measurement'), findsOneWidget);
    expect(
      calibration.isCalibrating,
      isTrue,
      reason: 'a fresh measurement must be running',
    );
    expect(
      calibration.progressFraction,
      lessThan(0.2),
      reason: 'the timer must count from zero again',
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'))
          .onPressed,
      isNull,
      reason: 'continuing is blocked until the new measurement finishes',
    );
  });

  test('reset discards the previous run baseline and elapsed time', () {
    final calibration = HrCalibration()
      ..setManualResult(baseline: 70, trigger: 85);
    expect(calibration.latestResult, isNotNull);

    calibration.reset();

    expect(
      calibration.latestResult,
      isNull,
      reason: 'a reopened demo must not reuse the previous baseline',
    );
    expect(calibration.isCalibrating, isFalse);
    expect(calibration.elapsedSeconds, 0);
  });
}
