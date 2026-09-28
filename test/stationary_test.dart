import 'package:birdlog_app_webversion/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'fixed location and session membership survive snapshots and deletion',
    () async {
      final db = await BirdLogDatabase.openInMemory();
      addTearDown(db.close);
      final start = DateTime(2026, 9, 26, 9);
      final session = StationarySession(
        id: 'fixed',
        tripId: 'trip',
        startedAt: start,
        latitude: 35,
        longitude: 139,
        accuracy: 10,
        locationTime: start,
      );
      final record = BirdRecord(
        id: 'bird',
        tripId: 'trip',
        species: 'スズメ',
        count: '2',
        time: start.add(const Duration(minutes: 5)),
        latitude: 35,
        longitude: 139,
        stationarySessionId: session.id,
      );
      Future<void> save() => db.saveSnapshot(
        trips: [BirdTrip(id: 'trip', startedAt: start)],
        records: [record],
        birdLists: {},
        stationarySessions: [session],
      );
      await save();
      final active = (await db.loadStationarySessions()).single;
      expect(active.endedAt, isNull);
      expect(active.latitude, 35);
      expect(active.locationTime, start);
      expect((await db.loadRecords()).single.stationarySessionId, active.id);
      session.endedAt = start.add(const Duration(minutes: 20));
      await save();
      final finished = (await db.loadStationarySessions()).single;
      expect(
        finished.endedAt!.difference(finished.startedAt),
        const Duration(minutes: 20),
      );
      await db.saveSnapshot(
        trips: [],
        records: [],
        birdLists: {},
        stationarySessions: [],
      );
      expect(await db.loadStationarySessions(), isEmpty);
      expect(await db.loadRecords(), isEmpty);
    },
  );
}
