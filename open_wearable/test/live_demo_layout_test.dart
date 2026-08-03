import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_wearable/apps/calmables/model/hr_calibration.dart';
import 'package:open_wearable/apps/calmables/model/ppg_filter.dart';
import 'package:open_wearable/apps/calmables/widgets/live_demo_page.dart';
import 'package:open_wearable/apps/calmables/widgets/rolling_hr_chart.dart';

/// Guards the shared layout anchors of the guided demo: the icon, heading,
/// chart and primary button must sit at identical coordinates on every screen,
/// and nothing may overflow the viewport. Overflowing renders fail the test on
/// their own, so simply walking the flow also covers the clipping criterion.
void main() {
  const devices = <String, (Size, double)>{
    'iPhone SE': (Size(750, 1334), 2.0),
    'iPhone 14 Pro': (Size(1179, 2556), 3.0),
  };

  devices.forEach((name, spec) {
    testWidgets('layout anchors align across screens — $name', (tester) async {
      final (size, ratio) = spec;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = ratio;
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

      // The breathing and relaxation visuals repeat forever, so settling is
      // only possible on the static screens.
      Future<void> advance() async {
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      double? topOf(Finder finder) => finder.evaluate().isEmpty
          ? null
          : tester.getTopLeft(finder.first).dy;

      final iconTops = <double>{};
      final headingTops = <double>{};
      final buttonTops = <double>{};
      final chartTops = <double>{};
      final chartHeights = <double>{};
      final kpiRects = <String, Rect>{};

      void record(String screen, String heading) {
        iconTops.add(topOf(find.byType(Icon))!);
        headingTops.add(topOf(find.text(heading))!);

        final button = topOf(find.byType(FilledButton));
        if (button != null) buttonTops.add(button);

        final chart = find.byType(RollingHrChart);
        if (chart.evaluate().isNotEmpty) {
          chartTops.add(tester.getTopLeft(chart.first).dy);
          chartHeights.add(tester.getSize(chart.first).height);
        }

        final label = find.text('Trigger threshold');
        if (label.evaluate().isNotEmpty) {
          kpiRects[screen] = tester.getRect(
            find.ancestor(of: label, matching: find.byType(Container)).first,
          );
        }
      }

      hr.add(72);
      await tester.pump(const Duration(milliseconds: 400));
      record('ready', 'Calmables');

      await tester.tap(find.text('Start Demo'));
      await tester.pumpAndSettle();
      record('intensity', 'Stimulation intensity');

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      record('baseline', 'Baseline measurement');

      await tester.tap(find.text('Continue'));
      await advance();
      record('breathing', 'Brief activation');

      for (var i = 0; i < 4; i++) {
        hr.add(95);
        await tester.pump(const Duration(milliseconds: 300));
      }
      await advance();
      record('relaxation', 'Relaxation');

      await tester.pump(const Duration(seconds: 31));
      await tester.tap(find.text('End relaxation'));
      await advance();
      record('welcomeBack', 'Welcome back.');

      expect(iconTops, hasLength(1), reason: 'icon tops: $iconTops');
      expect(headingTops, hasLength(1), reason: 'heading tops: $headingTops');
      expect(buttonTops, hasLength(1), reason: 'button tops: $buttonTops');
      expect(chartTops, hasLength(1), reason: 'chart tops: $chartTops');
      expect(
        chartHeights,
        hasLength(1),
        reason: 'chart heights: $chartHeights',
      );
      expect(
        kpiRects['baseline'],
        kpiRects['breathing'],
        reason: 'KPI cards must match between baseline and activation',
      );

      // Walk the survey to the summary so those screens are laid out too.
      await tester.tap(find.text("I'm back"));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Strongly Agree'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Strongly Agree'));
      await tester.pumpAndSettle();
      expect(find.text('Demo complete'), findsOneWidget);
    });
  });
}
