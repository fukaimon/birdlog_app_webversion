// 観察場所・日時・地名はテスト用の架空データです。実際の観察記録は使わないでください。
import 'dart:async';
import 'dart:convert';

import 'package:birdlog_app_webversion/main.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 位置情報プラグインの差し替え。既定ではサービス無効（位置情報なし）。
class _FakeGeolocatorPlatform extends GeolocatorPlatform {
  bool serviceEnabled = false;
  int streamStarts = 0;
  Completer<bool>? nextServiceCheck;
  bool get locating => _positions.hasListener;
  final _positions = StreamController<Position>.broadcast(sync: true);

  @override
  Future<bool> isLocationServiceEnabled() async {
    final pending = nextServiceCheck;
    nextServiceCheck = null;
    return pending == null ? serviceEnabled : await pending.future;
  }

  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;

  @override
  Future<LocationPermission> requestPermission() async =>
      LocationPermission.whileInUse;

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    streamStarts++;
    return _positions.stream;
  }

  void addPosition(double accuracy) {
    _positions.add(
      Position(
        latitude: 35.681236,
        longitude: 139.767125,
        timestamp: DateTime.now(),
        accuracy: accuracy,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      ),
    );
  }

  Future<void> dispose() => _positions.close();
}

Future<void> _pumpBirdLogApp(WidgetTester tester) async {
  await tester.pumpWidget(const BirdLogApp());
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeGeolocatorPlatform fakeGeolocator;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugOpenBirdLogDatabase = () async {
      final db = await BirdLogDatabase.openInMemory();
      final prefs = await SharedPreferences.getInstance();
      List<Map<String, dynamic>> rows(String key) =>
          (jsonDecode(prefs.getString(key) ?? '[]') as List)
              .map((r) => Map<String, dynamic>.from(r as Map))
              .toList();
      await db.saveSnapshot(
        trips: rows('birdTripsFlutter').map(BirdTrip.fromJson).toList(),
        records: rows('birdLogsFlutter').map(BirdRecord.fromJson).toList(),
        birdLists:
            (jsonDecode(prefs.getString('birdListsFlutter') ?? '{}') as Map)
                .map(
                  (k, v) => MapEntry(k as String, (v as List).cast<String>()),
                ),
      );
      return db;
    };
    fakeGeolocator = _FakeGeolocatorPlatform();
    GeolocatorPlatform.instance = fakeGeolocator;
  });

  tearDown(() async {
    await fakeGeolocator.dispose();
    debugOpenBirdLogDatabase = null;
  });

  testWidgets(
    'species-only saves no observation details and resets after one record',
    (tester) async {
      fakeGeolocator.serviceEnabled = true;
      late BirdLogDatabase db;
      debugOpenBirdLogDatabase = () async =>
          db = await BirdLogDatabase.openInMemory();
      await _pumpBirdLogApp(tester);
      await tester.tap(find.text('新しく始める'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '種名'), 'トビ');
      final mode = find.byKey(const Key('species-only-mode'));
      await tester.scrollUntilVisible(
        mode,
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(tester.element(mode), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(mode);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(mode).value, isTrue);
      await tester.tap(find.widgetWithText(FilledButton, '記録'));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(mode).value, isFalse);
      expect(fakeGeolocator.streamStarts, 1);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final record = (await db.loadRecords()).single;
        expect(record.speciesOnly, isTrue);
        expect(record.species, 'トビ');
        expect(record.time, isNull);
        expect(record.count, isEmpty);
        expect(record.latitude, isNull);
        expect(record.longitude, isNull);
        expect(record.locationTime, isNull);
        expect(record.stationarySessionId, isNull);
        expect(record.comment, isEmpty);
      });
      ScaffoldMessenger.of(
        tester.element(find.byType(Scaffold).first),
      ).hideCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.tap(find.text('編集'));
      await tester.pumpAndSettle();
      expect(find.text(speciesOnlyHeading), findsOneWidget);
      await tester.tap(
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '編集'),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '時間'), findsNothing);
      expect(find.widgetWithText(TextField, '数'), findsNothing);
      await tester.enterText(find.widgetWithText(TextField, '鳥の名前'), 'スズメ');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('集計'));
      await tester.pumpAndSettle();
      final summary = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((w) => w.data!)
          .toList();
      expect(summary.first, endsWith('\nスズメ'));
      expect(summary.first, isNot(contains('スズメ 0')));
      expect(
        summary.where((text) => text == '$speciesOnlyHeading\nスズメ'),
        isNotEmpty,
      );
      await tester.tap(find.text('マップ'));
      await tester.pumpAndSettle();
      expect(find.text('$speciesOnlyHeading\nスズメ'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('map-record-'),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'species-only overrides a fixed location and remains separate in exports',
    (tester) async {
      final start = DateTime(2026, 9, 26, 9);
      late BirdLogDatabase db;
      SharedPreferences.setMockInitialValues({
        'birdlog_app_webversion.view': 'trip',
        'birdlog_app_webversion.currentTrip': 'trip',
      });
      debugOpenBirdLogDatabase = () async {
        db = await BirdLogDatabase.openInMemory();
        await db.saveSnapshot(
          trips: [BirdTrip(id: 'trip', startedAt: start)],
          records: [
            BirdRecord(
              id: 'normal',
              tripId: 'trip',
              species: 'スズメ',
              count: '3',
              time: start,
            ),
          ],
          birdLists: {
            'trip': ['スズメ'],
          },
          stationarySessions: [
            StationarySession(
              id: 'fixed',
              tripId: 'trip',
              startedAt: start,
              latitude: 35,
              longitude: 139,
              accuracy: 10,
              locationTime: start,
            ),
          ],
        );
        return db;
      };
      await _pumpBirdLogApp(tester);
      await tester.enterText(find.widgetWithText(TextField, '種名'), 'スズメ');
      final mode = find.byKey(const Key('species-only-mode'));
      await tester.scrollUntilVisible(
        mode,
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(tester.element(mode), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(mode);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '記録'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final record = (await db.loadRecords()).firstWhere(
          (r) => r.speciesOnly,
        );
        expect(record.latitude, isNull);
        expect(record.stationarySessionId, isNull);
        expect((await db.loadStationarySessions()).single.endedAt, isNull);
      });
      expect(fakeGeolocator.streamStarts, 0);
      await tester.tap(find.text('集計'));
      await tester.pumpAndSettle();
      final texts = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((w) => w.data!)
          .toList();
      expect(texts.first, contains('スズメ 3（種のみの記録あり）'));
      expect(
        texts
            .skip(1)
            .every((text) => text.endsWith('$speciesOnlyHeading\nスズメ')),
        isTrue,
      );
      for (final title in ['字名ごとの記録', '記録ごと（位置情報あり）', '記録ごと（位置情報なし）']) {
        await tester.scrollUntilVisible(
          find.text(title),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        final panel = find.ancestor(
          of: find.text(title),
          matching: find.byType(ExpansionTile),
        );
        final text = tester
            .widget<SelectableText>(
              find.descendant(of: panel, matching: find.byType(SelectableText)),
            )
            .data!;
        expect(text, endsWith('$speciesOnlyHeading\nスズメ'));
      }
    },
  );

  testWidgets(
    'stationary fixes once, groups records, and persists the interval',
    (tester) async {
      fakeGeolocator.serviceEnabled = true;
      late BirdLogDatabase db;
      debugOpenBirdLogDatabase = () async =>
          db = await BirdLogDatabase.openInMemory();
      await _pumpBirdLogApp(tester);
      await tester.tap(find.text('新しく始める'));
      await tester.pumpAndSettle();
      final toggle = find.widgetWithText(SwitchListTile, '定点モード');
      await tester.scrollUntilVisible(
        toggle,
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(toggle);
      await tester.pump();
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      fakeGeolocator.addPosition(10);
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(fakeGeolocator.streamStarts, 2);
      expect(fakeGeolocator.locating, isFalse);
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '更新'))
            .onPressed,
        isNull,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fakeGeolocator.locating, isFalse);
      for (final name in ['スズメ', 'トビ']) {
        final field = find.widgetWithText(TextField, '種名');
        await tester.scrollUntilVisible(
          field,
          -160,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(field, name);
        await tester.tap(find.widgetWithText(FilledButton, '記録'));
        await tester.pumpAndSettle();
      }
      expect(fakeGeolocator.streamStarts, 2);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final records = await db.loadRecords();
        expect(records, hasLength(2));
        expect(records.map((r) => r.latitude).toSet(), {35.681236});
        expect(records.map((r) => r.locationTime).toSet(), hasLength(1));
        expect(records.map((r) => r.stationarySessionId).toSet(), hasLength(1));
      });
      ScaffoldMessenger.of(
        tester.element(find.byType(Scaffold).first),
      ).hideCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        toggle,
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      late StationarySession session;
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        session = (await db.loadStationarySessions()).single;
        expect(session.endedAt, isNotNull);
      });
      await tester.tap(find.text('マップ'));
      await tester.pumpAndSettle();
      final marker = find.byKey(Key('map-stationary-${session.id}'));
      expect(marker, findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('map-record-'),
        ),
        findsNothing,
      );
      await tester.tap(marker);
      await tester.pumpAndSettle();
      expect(find.text('記録された種（2種）'), findsOneWidget);
      expect(find.textContaining('開始：'), findsOneWidget);
      expect(find.textContaining('終了：'), findsOneWidget);
    },
  );

  testWidgets(
    'stationary cancels an in-flight location start and resumes after off',
    (tester) async {
      fakeGeolocator.serviceEnabled = true;
      await _pumpBirdLogApp(tester);
      final pending = Completer<bool>();
      fakeGeolocator.nextServiceCheck = pending;
      await tester.tap(find.text('新しく始める'));
      await tester.pumpAndSettle();
      final refresh = find.widgetWithText(OutlinedButton, '更新');
      await tester.scrollUntilVisible(
        refresh,
        160,
        scrollable: find.byType(Scrollable).first,
      );
      final toggle = find.widgetWithText(SwitchListTile, '定点モード');
      await tester.scrollUntilVisible(
        toggle,
        -120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pump();
      await tester.pump();
      expect(fakeGeolocator.streamStarts, 1);
      // The obsolete request finishes while the new acquisition is in progress.
      pending.complete(true);
      await tester.pump();
      expect(fakeGeolocator.streamStarts, 1);
      fakeGeolocator.addPosition(10);
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(fakeGeolocator.locating, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        refresh,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(refresh);
      await tester.pump();
      expect(fakeGeolocator.locating, isTrue);
      expect(fakeGeolocator.streamStarts, 2);
    },
  );

  testWidgets('stationary remains off if location is unavailable', (
    tester,
  ) async {
    await _pumpBirdLogApp(tester);
    await tester.tap(find.text('新しく始める'));
    await tester.pumpAndSettle();
    final toggle = find.widgetWithText(SwitchListTile, '定点モード');
    await tester.scrollUntilVisible(
      toggle,
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(find.text('位置を取得できなかったため、定点モードを開始できませんでした'), findsOneWidget);
  });

  testWidgets('shows the Bird Log cover page', (tester) async {
    await _pumpBirdLogApp(tester);

    expect(find.text('birdlog_app_webversion'), findsOneWidget);
    expect(find.text('新しく始める'), findsOneWidget);
    expect(find.text('過去の記録を見る'), findsOneWidget);
  });

  testWidgets('opens a new location bird log trip', (tester) async {
    await _pumpBirdLogApp(tester);

    await tester.tap(find.text('新しく始める'));
    await tester.pumpAndSettle();

    expect(find.text('記録'), findsWidgets);
    expect(find.text('編集'), findsOneWidget);
    expect(find.text('集計'), findsOneWidget);
    expect(find.text('マップ'), findsOneWidget);
    expect(find.text('設定'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.textContaining('緯度・経度'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('緯度・経度'), findsOneWidget);
    expect(
      tester.getTopLeft(find.widgetWithText(FilterChip, '+')).dy,
      tester.getTopLeft(find.widgetWithText(FilterChip, '±')).dy,
    );
    expect(
      tester.getTopLeft(find.widgetWithText(FilterChip, 's')).dy,
      greaterThan(tester.getTopLeft(find.widgetWithText(FilterChip, '+')).dy),
    );
  });

  testWidgets('opens wheel picker from time clock buttons', (tester) async {
    await _pumpBirdLogApp(tester);

    await tester.tap(find.text('新しく始める'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('開始時刻を選択'));
    await tester.pumpAndSettle();

    expect(find.text('開始時刻'), findsOneWidget);
    expect(find.text('時'), findsOneWidget);
    expect(find.text('分'), findsOneWidget);
    expect(find.byType(CupertinoPicker), findsNWidgets(2));
    expect(find.text('決定'), findsOneWidget);
  });

  testWidgets('saves a bird record without location', (tester) async {
    await _pumpBirdLogApp(tester);

    await tester.tap(find.text('新しく始める'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '種名').first, 'スズメ');
    await tester.tap(find.widgetWithText(FilledButton, '3'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '記録'));
    await tester.pumpAndSettle();

    expect(find.textContaining('位置情報なしで保存しました'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.textContaining('記録しました'), findsNothing);

    await tester.tap(find.text('編集'));
    await tester.pumpAndSettle();

    expect(find.text('スズメ  3'), findsOneWidget);
  });

  testWidgets('offers to add an unlisted bird and reflects the choice', (
    tester,
  ) async {
    await _pumpBirdLogApp(tester);
    await tester.tap(find.text('新しく始める'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '種名').first, 'スズメ');
    await tester.tap(find.widgetWithText(FilledButton, '記録'));
    await tester.pumpAndSettle();
    expect(find.textContaining('「スズメ」をよく見る鳥に追加しますか？'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'スズメ'), findsNothing);
    await tester.tap(find.text('追加する'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'スズメ'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'スズメ'));
    await tester.tap(find.widgetWithText(FilledButton, '記録'));
    await tester.pumpAndSettle();
    expect(find.textContaining('よく見る鳥に追加しますか？'), findsNothing);
    await tester.tap(find.text('設定'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'スズメ'), findsOneWidget);
  });

  testWidgets('keeps a high-accuracy location stream until it reaches 20m', (
    tester,
  ) async {
    fakeGeolocator.serviceEnabled = true;

    await _pumpBirdLogApp(tester);
    await tester.tap(find.text('新しく始める'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, '種名').first, 'トビ');
    // 種名を入力して記録すると、連続測位を開始する。
    await tester.tap(find.widgetWithText(FilledButton, '記録'));
    await tester.pump();
    await tester.pump();
    fakeGeolocator.addPosition(60);
    await tester.pump();
    fakeGeolocator.addPosition(12);
    await tester.pump();

    expect(fakeGeolocator.streamStarts, 1);
    await tester.scrollUntilVisible(
      find.textContaining('現在地を取得しました'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('現在地を取得しました（±12m・高精度測位を継続中）'), findsOneWidget);
  });

  testWidgets('uses the latest position from the continuous location stream', (
    tester,
  ) async {
    fakeGeolocator.serviceEnabled = true;

    await _pumpBirdLogApp(tester);
    await tester.tap(find.text('新しく始める'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, '種名').first, 'トビ');
    await tester.tap(find.widgetWithText(FilledButton, '記録'));
    await tester.pump();
    await tester.pump();
    fakeGeolocator.addPosition(12);
    await tester.pump();

    await tester.enterText(find.widgetWithText(TextField, '種名').first, 'トビ');
    await tester.tap(find.widgetWithText(FilledButton, '記録'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('編集'));
    await tester.pumpAndSettle();

    expect(find.textContaining('35.681236, 139.767125'), findsOneWidget);
  });

  testWidgets('saves before GPS and adds a later fix only after confirmation', (
    tester,
  ) async {
    fakeGeolocator.serviceEnabled = true;
    late BirdLogDatabase db;
    debugOpenBirdLogDatabase = () async =>
        db = await BirdLogDatabase.openInMemory();
    await _pumpBirdLogApp(tester);
    await tester.tap(find.text('新しく始める'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '種名').first, 'アオサギ');
    await tester.tap(find.widgetWithText(FilledButton, '記録'));
    await tester.pumpAndSettle();
    final saved = (await db.loadRecords()).single;
    expect(saved.species, 'アオサギ');
    expect(saved.latitude, isNull);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '記録'))
          .onPressed,
      isNotNull,
    );
    final observedAt = saved.time;
    fakeGeolocator.addPosition(80);
    fakeGeolocator.addPosition(45);
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect((await db.loadRecords()).single.latitude, isNull);
    // Dismiss the saved-record notice to reveal the queued confirmation.
    ScaffoldMessenger.of(
      tester.element(find.byType(Scaffold).first),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    expect(find.text('位置を追加'), findsOneWidget);
    await tester.tap(find.text('位置を追加'));
    await tester.pumpAndSettle();
    final located = (await db.loadRecords()).single;
    expect(located.latitude, 35.681236);
    expect(located.locationAccuracy, 45);
    expect(located.time, observedAt);
    expect(located.locationTime, isNotNull);
  });

  testWidgets('starts GPS on return and does not create duplicate streams', (
    tester,
  ) async {
    fakeGeolocator.serviceEnabled = true;
    await _pumpBirdLogApp(tester);
    await tester.tap(find.text('新しく始める'));
    await tester.pumpAndSettle();
    expect(fakeGeolocator.streamStarts, 1);
    expect(fakeGeolocator.locating, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(fakeGeolocator.locating, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(fakeGeolocator.streamStarts, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(fakeGeolocator.streamStarts, 2);
    expect(find.text('行動の記録'), findsNothing);
  });

  testWidgets('keeps the quick bird list independent for each trip', (
    tester,
  ) async {
    await _pumpBirdLogApp(tester);

    await tester.tap(find.text('新しく始める'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('設定'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '種名'), 'ハシボソガラス');
    await tester.tap(find.widgetWithText(FilledButton, '追加'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.home_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新しく始める'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ChoiceChip, 'ハシボソガラス'), findsNothing);
  });

  testWidgets('confirms and can undo trip deletion', (tester) async {
    await _pumpBirdLogApp(tester);
    await tester.tap(find.text('新しく始める'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.home_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('過去の記録を見る'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('トリップを削除しますか？'), findsOneWidget);

    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '削除'));
    await tester.pumpAndSettle();
    expect(find.text('トリップを削除しました'), findsOneWidget);

    await tester.tap(find.text('元に戻す'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('過去の記録を見る'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });

  for (final dismissByTap in [false, true]) {
    testWidgets(
      'dismisses trip deletion notice by ${dismissByTap ? 'outside tap' : 'timeout'}',
      (tester) async {
        await _pumpBirdLogApp(tester);
        await tester.tap(find.text('新しく始める'));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.home_outlined));
        await tester.pumpAndSettle();
        await tester.tap(find.text('過去の記録を見る'));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.delete_outline));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '削除'));
        await tester.pumpAndSettle();
        expect(find.text('元に戻す'), findsOneWidget);
        if (dismissByTap) {
          await tester.tapAt(const Offset(10, 100));
        } else {
          await tester.pump(const Duration(seconds: 4));
          expect(find.text('元に戻す'), findsOneWidget);
          await tester.pump(const Duration(seconds: 1));
        }
        await tester.pumpAndSettle();
        expect(find.text('元に戻す'), findsNothing);
        expect(find.text('トリップを削除しました'), findsNothing);
      },
    );
  }

  testWidgets('keeps the saved bird when leaving before GPS is ready', (
    tester,
  ) async {
    fakeGeolocator.serviceEnabled = true;

    await _pumpBirdLogApp(tester);
    await tester.tap(find.text('新しく始める'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '種名').first, 'トビ');
    await tester.tap(find.widgetWithText(FilledButton, '記録'));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.home_outlined));
    await tester.pumpAndSettle();
    expect(find.textContaining('記録を中止しました'), findsNothing);

    await tester.tap(find.text('過去の記録を見る'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ListTile).first);
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('編集'));
    await tester.pump();
    expect(find.text('トビ  1'), findsOneWidget);
  });

  testWidgets('shows edit sorting labels on one line and record location', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'birdlog_app_webversion.view': 'trip',
      'birdlog_app_webversion.currentTrip': 'trip-1',
      'birdListsFlutter': '{}',
      'birdTripsFlutter': jsonEncode([
        {
          'id': 'trip-1',
          'title': 'テスト観察地',
          'startTime': '09:00',
          'endTime': '12:00',
          'startedAt': '2000-01-01T09:00:00.000',
        },
      ]),
      'birdLogsFlutter': jsonEncode([
        {
          'id': 'record-1',
          'tripId': 'trip-1',
          'species': 'コチドリ',
          'count': '1',
          'time': '2000-01-01T10:00:00.000',
          'latitude': 35.000000,
          'longitude': 135.000000,
        },
      ]),
    });

    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await _pumpBirdLogApp(tester);
    await tester.tap(find.text('編集'));
    await tester.pumpAndSettle();

    expect(find.text('古い順'), findsOneWidget);
    expect(find.text('新しい順'), findsOneWidget);
    expect(find.text('時系列'), findsOneWidget);
    expect(find.text('種別'), findsOneWidget);
    expect(find.text('10:00  35.000000, 135.000000'), findsOneWidget);
  });

  testWidgets('edits record location from a map with satellite option', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'birdlog_app_webversion.view': 'trip',
      'birdlog_app_webversion.currentTrip': 'trip-1',
      'birdListsFlutter': '{}',
      'birdTripsFlutter': jsonEncode([
        {
          'id': 'trip-1',
          'title': 'テスト観察地',
          'startedAt': '2000-01-01T09:00:00.000',
        },
      ]),
      'birdLogsFlutter': jsonEncode([
        {
          'id': 'record-1',
          'tripId': 'trip-1',
          'species': 'コチドリ',
          'count': '1',
          'time': '2000-01-01T10:00:00.000',
        },
      ]),
    });

    await _pumpBirdLogApp(tester);
    await tester.tap(find.text('編集'));
    await tester.pumpAndSettle();
    expect(find.text('10:00'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('位置情報を全画面で編集'));
    await tester.pumpAndSettle();

    expect(find.text('位置情報を編集'), findsOneWidget);
    expect(find.text('航空写真'), findsOneWidget);
    expect(find.byKey(const Key('cardinal-direction')), findsOneWidget);
    expect(find.text('地図を長押しして位置情報を設定'), findsOneWidget);

    await tester.tap(find.text('航空写真'));
    await tester.pumpAndSettle();
    await tester.longPressAt(tester.getCenter(find.byType(FlutterMap)));
    await tester.pumpAndSettle();

    expect(find.text('地図を長押しして位置情報を設定'), findsNothing);
    await tester.tap(find.text('完了'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.textContaining(', '), findsOneWidget);
  });

  testWidgets('shows trip header only in species total export', (tester) async {
    SharedPreferences.setMockInitialValues({
      'birdlog_app_webversion.view': 'trip',
      'birdlog_app_webversion.currentTrip': 'trip-1',
      'birdListsFlutter': '{}',
      'birdTripsFlutter': jsonEncode([
        {
          'id': 'trip-1',
          'title': 'テスト観察地',
          'startTime': '09:00',
          'endTime': '12:00',
          'startedAt': '2000-01-01T09:00:00.000',
        },
      ]),
      'birdLogsFlutter': jsonEncode([
        {
          'id': 'record-1',
          'tripId': 'trip-1',
          'species': 'コチドリ',
          'count': '1',
          'time': '2000-01-01T10:00:00.000',
          'latitude': 35.000000,
          'longitude': 135.000000,
          'placeName': '架空県 テスト市 サンプル公園',
        },
      ]),
    });

    await _pumpBirdLogApp(tester);
    await tester.tap(find.text('集計'));
    await tester.pumpAndSettle();

    expect(find.text('時間ごとの総計'), findsNothing);

    final texts = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((widget) => widget.data ?? '')
        .toList();
    final header = '2000/01/01 09:00-12:00 テスト観察地';

    expect(texts.where((text) => text.startsWith(header)), hasLength(1));
    expect(
      texts.firstWhere((text) => text.contains('コチドリ 1')),
      startsWith(header),
    );
    expect(
      texts.firstWhere((text) => text.contains('10:00\tコチドリ')),
      isNot(contains(header)),
    );
    expect(
      texts.firstWhere((text) => text.contains('架空県 テスト市 サンプル公園')),
      contains('コチドリ 1'),
    );
  });

  testWidgets('map shows stored location markers and record actions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'birdlog_app_webversion.view': 'trip',
      'birdlog_app_webversion.currentTrip': 'trip-1',
      'birdListsFlutter': '{}',
      'birdTripsFlutter': jsonEncode([
        {
          'id': 'trip-1',
          'title': 'テスト観察地',
          'startedAt': '2000-01-01T09:00:00.000',
        },
      ]),
      'birdLogsFlutter': jsonEncode([
        {
          'id': 'record-1',
          'tripId': 'trip-1',
          'species': 'コチドリ',
          'count': '3',
          'time': '2000-01-01T10:00:00.000',
          'latitude': 35.000000,
          'longitude': 135.000000,
          'locationAccuracy': 8,
          'comment': 'テスト用コメント',
        },
        {
          'id': 'record-2',
          'tripId': 'trip-1',
          'species': 'カルガモ',
          'count': '25',
          'time': '2000-01-01T10:10:00.000',
          'latitude': 35.000329,
          'longitude': 135.000869,
        },
      ]),
    });

    await _pumpBirdLogApp(tester);
    await tester.tap(find.text('マップ'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('map-record-record-1')), findsOneWidget);
    expect(find.byKey(const Key('map-record-record-2')), findsOneWidget);
    expect(find.byTooltip('地図を再読み込み'), findsOneWidget);
    expect(find.byTooltip('表示する種'), findsOneWidget);
    expect(find.text('航空写真'), findsOneWidget);
    expect(find.text('凡例（種別）'), findsOneWidget);
    expect(find.text('コチドリ'), findsWidgets);
    expect(find.text('カルガモ'), findsOneWidget);

    final legendStart = tester.getTopLeft(find.text('凡例（種別）'));
    await tester.drag(find.text('凡例（種別）'), const Offset(70, 40));
    await tester.pump();
    expect(tester.getTopLeft(find.text('凡例（種別）')), isNot(legendStart));

    await tester.tap(find.text('航空写真'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('表示する種'));
    await tester.pumpAndSettle();
    expect(find.text('地図に表示する種'), findsOneWidget);
    expect(find.text('全選択'), findsOneWidget);
    expect(find.text('選択解除'), findsOneWidget);
    await tester.tap(find.text('選択解除'));
    await tester.pump();
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, 'コチドリ'))
          .selected,
      isFalse,
    );
    await tester.tap(find.text('全選択'));
    await tester.pump();
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, 'コチドリ'))
          .selected,
      isTrue,
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('map-record-record-1')));
    await tester.pumpAndSettle();
    expect(find.text('コチドリ'), findsWidgets);
    expect(find.textContaining('位置: 35.000000, 135.000000'), findsOneWidget);
    expect(find.text('コメント: テスト用コメント'), findsOneWidget);

    await tester.tap(find.text('緯度・経度をコピー'));
    await tester.pumpAndSettle();
    expect(find.text('コピーしました'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '記録を編集'));
    await tester.pumpAndSettle();
    expect(find.text('記録を編集'), findsOneWidget);
    expect(find.text('コメント'), findsOneWidget);
  });
}
