import 'dart:convert';

import '../models.dart';
import 'platform.dart' as platform;

/// The web bridge commits one IndexedDB transaction for each batch. The memory
/// backend is only for tests; a browser storage failure never falls back to it.
class BirdLogDatabase {
  BirdLogDatabase._({this.memory = false});
  final bool memory;
  final _known = <String, Map<String, String>>{};
  final _rows = <String, Map<String, Map<String, dynamic>>>{};

  static Future<BirdLogDatabase> open() async {
    await platform.call('open');
    return BirdLogDatabase._();
  }

  static Future<BirdLogDatabase> openInMemory() async =>
      BirdLogDatabase._(memory: true);

  Future<List<Map<String, dynamic>>> _read(String store) async {
    final List<Map<String, dynamic>> rows;
    if (memory) {
      rows = (_rows[store]?.values ?? [])
          .map(
            (r) => Map<String, dynamic>.from(jsonDecode(jsonEncode(r)) as Map),
          )
          .toList();
    } else {
      rows = (await platform.call('read', store) as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
    }
    _known[store] = {
      for (final row in rows) row['id'] as String: jsonEncode(row),
    };
    return rows;
  }

  Future<void> _write(List<Map<String, dynamic>> changes) async {
    if (changes.isEmpty) return;
    if (memory) {
      for (final change in changes) {
        final rows = _rows.putIfAbsent(change['store'] as String, () => {});
        for (final id in change['delete'] as List) {
          rows.remove(id);
        }
        for (final row in change['put'] as List<Map<String, dynamic>>) {
          rows[row['id'] as String] = Map<String, dynamic>.from(
            jsonDecode(jsonEncode(row)) as Map,
          );
        }
      }
    } else {
      await platform.call('write', changes);
    }
  }

  Future<List<BirdTrip>> loadTrips() async =>
      (await _read('trips')).map(BirdTrip.fromJson).toList()
        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

  Future<List<BirdRecord>> loadRecords() async =>
      (await _read('records')).map(BirdRecord.fromJson).toList();

  Future<Map<String, List<String>>> loadBirdLists() async => {
    for (final row in await _read('bird_lists'))
      row['id'] as String: (row['birds'] as List).cast<String>(),
  };

  Future<List<StationarySession>> loadStationarySessions() async =>
      (await _read(
          'stationary_sessions',
        )).map(StationarySession.fromRow).toList()
        ..sort((a, b) => a.startedAt.compareTo(b.startedAt));

  Future<void> close() async {
    if (!memory) await platform.call('close');
  }

  /// Compare against the last successful commit, never delete/reinsert tables.
  /// A failed transaction leaves the baseline intact so a retry includes edits.
  Future<void> saveSnapshot({
    required List<BirdTrip> trips,
    required List<BirdRecord> records,
    required Map<String, List<String>> birdLists,
    List<StationarySession>? stationarySessions,
  }) async {
    final stores = <String, List<Map<String, dynamic>>>{
      'trips': trips.map((t) => t.toJson()).toList(),
      'records': records.map((r) => r.toJson()).toList(),
      'bird_lists': [
        for (final e in birdLists.entries) {'id': e.key, 'birds': e.value},
      ],
      if (stationarySessions != null)
        'stationary_sessions': stationarySessions
            .map((s) => s.toRow())
            .toList(),
    };
    final next = <String, Map<String, String>>{};
    final changes = <Map<String, dynamic>>[];
    for (final entry in stores.entries) {
      final old = _known[entry.key] ?? {};
      final encoded = {
        for (final r in entry.value) r['id'] as String: jsonEncode(r),
      };
      next[entry.key] = encoded;
      final put = entry.value
          .where((r) => old[r['id']] != encoded[r['id']])
          .toList();
      final deleted = old.keys.where((id) => !encoded.containsKey(id)).toList();
      if (put.isNotEmpty || deleted.isNotEmpty) {
        changes.add({'store': entry.key, 'put': put, 'delete': deleted});
      }
    }
    await _write(changes);
    _known.addAll(next);
  }
}
