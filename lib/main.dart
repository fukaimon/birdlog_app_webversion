import 'dart:async';

import 'models.dart';
import 'storage/database.dart';
import 'storage/platform.dart' as platform;

export 'models.dart';
export 'storage/database.dart';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'species.dart';

typedef BirdLogDatabaseOpener = Future<BirdLogDatabase> Function();

BirdLogDatabaseOpener? debugOpenBirdLogDatabase;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 地図タイルは Flutter 共有の ImageCache を経由する。連続ズームでも
  // 直前のタイルを保持できるよう、地図表示に十分な容量を確保する。
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 1000;
  imageCache.maximumSizeBytes =
      64 << 20; // 64 MiB: avoid excessive mobile browser memory use.
  try {
    final loader = FontLoader('NotoSansJP');
    loader.addFont(
      NetworkAssetBundle(
        Uri.parse(
          'https://raw.githubusercontent.com/google/fonts/main/ofl/notosansjp/NotoSansJP%5Bwght%5D.ttf',
        ),
      ).load(''),
    );
    await loader.load().timeout(const Duration(seconds: 30));
  } on Object {
    // Startup UI reports whether offline preparation succeeded; the browser's
    // normal fallback remains usable if the font host is temporarily unavailable.
  }
  runApp(const BirdLogApp());
}

String _pad2(int value) => value.toString().padLeft(2, '0');

String _clockText(DateTime date) => '${_pad2(date.hour)}:${_pad2(date.minute)}';

String _calendarText(DateTime date) =>
    '${date.year}/${_pad2(date.month)}/${_pad2(date.day)}';

int _numericCountOf(String count) {
  final match = RegExp(r'\d+').firstMatch(count);
  return int.tryParse(match?.group(0) ?? '') ?? 0;
}

class BirdLogApp extends StatelessWidget {
  const BirdLogApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'birdlog_app_webversion',
      theme: ThemeData(
        fontFamily: 'NotoSansJP',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff1f6f5b),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xfff7f7f2),
        useMaterial3: true,
      ),
      home: const BirdLogHome(),
    );
  }
}

enum AppView { cover, past, trip }

enum TripTab { record, edit, logs, map, settings }

class TwoDigitTimeInputFormatter extends TextInputFormatter {
  const TwoDigitTimeInputFormatter({required this.max});

  final int max;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return const TextEditingValue();
    final limited = digits.length > 2
        ? digits.substring(digits.length - 2)
        : digits;
    final value = int.parse(limited).clamp(0, max);
    final text = value.toString().padLeft(2, '0');
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

class BirdLogHome extends StatefulWidget {
  const BirdLogHome({super.key});

  @override
  State<BirdLogHome> createState() => _BirdLogHomeState();
}

class _BirdLogHomeState extends State<BirdLogHome> with WidgetsBindingObserver {
  static const _currentTripKey = 'birdlog_app_webversion.currentTrip';
  static const _appViewKey = 'birdlog_app_webversion.view';
  static const _detailCodes = ['s', 'c', 'ad', 'j', 'm', 'f'];

  /// 現在地の目標精度（メートル）。
  static const _locationTargetAccuracy = 20.0;
  static const _recordLocationMaxAge = Duration(seconds: 10);
  static const _recordLocationWaitLimit = Duration(seconds: 30);

  final _speciesController = TextEditingController();
  final _commentController = TextEditingController();
  final _newBirdController = TextEditingController();
  final _tripTitleController = TextEditingController();
  final _startHourController = TextEditingController();
  final _startMinuteController = TextEditingController();
  final _endHourController = TextEditingController();
  final _endMinuteController = TextEditingController();

  SharedPreferences? _prefs;
  BirdLogDatabase? _db;
  Future<void> _saveQueue = Future.value();
  AppView _view = AppView.cover;
  TripTab _tab = TripTab.record;
  List<BirdTrip> _trips = [];
  List<BirdRecord> _records = [];
  List<StationarySession> _stationarySessions = [];
  bool _changingStationary = false;
  StationarySession? get _activeStationary => _stationarySessions
      .where((s) => s.tripId == _currentTripId && s.endedAt == null)
      .firstOrNull;
  Map<String, List<String>> _birdLists = {};
  String _currentTripId = '';
  int _count = 1;
  bool _countAddMode = false;
  String _approx = '';
  final Set<String> _details = {};
  bool _loading = true;
  bool _newestFirst = false;
  bool _groupBySpecies = false;
  bool _refreshingLocation = false;
  bool _savingRecord = false;
  bool _speciesOnlyMode = false;
  GlobalKey? _undoSnackBarKey;
  bool _fetchingPlaceNames = false;
  int _placeNamesProcessed = 0;
  int _placeNamesTotal = 0;
  bool _autoLocationActive = false;
  bool _startingLocationStream = false;
  int _locationGeneration = 0;
  StreamSubscription<Position>? _locationSubscription;
  Completer<Position?>? _pendingRecordPosition;
  Position? _pendingRecordBestPosition;
  bool _pendingRecordHasNewPosition = false;
  Timer? _recordLocationWaitTimer;
  Position? _currentLocation;
  DateTime? _currentLocationUpdatedAt;
  String _locationStatus = '現在地は未取得です';
  final _recordLocationTimers = <String, Timer>{};
  final _locationCandidates = <String, Position>{};

  BirdTrip? get _currentTrip {
    for (final trip in _trips) {
      if (trip.id == _currentTripId) return trip;
    }
    return null;
  }

  List<BirdRecord> get _visibleRecords {
    return _records.where((record) => record.tripId == _currentTripId).toList();
  }

  List<String> get _birdList {
    return _speciesInEighthEditionOrder(_birdLists[_currentTripId] ?? const []);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAutoLocation();
    _completePendingRecordPosition(null);
    final db = _db;
    unawaited(_saveQueue.then((_) => db?.close()));
    _speciesController.dispose();
    _commentController.dispose();
    _newBirdController.dispose();
    _tripTitleController.dispose();
    _startHourController.dispose();
    _startMinuteController.dispose();
    _endHourController.dispose();
    _endMinuteController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      // A web page cannot keep tracking reliably once it is hidden.
      unawaited(_stopAutoLocation());
      _completePendingRecordPosition(null);
    } else if (state == AppLifecycleState.resumed) {
      _resumeLocation();
    }
  }

  void _resumeLocation() {
    final state = WidgetsBinding.instance.lifecycleState;
    if (!_loading &&
        _view == AppView.trip &&
        _currentTrip != null &&
        (state == null || state == AppLifecycleState.resumed)) {
      _startAutoLocation();
    }
  }

  String? _loadError;
  String _storageStatus = '保存状態は「確認」で表示できます。';

  Future<void> _checkStorage() async {
    try {
      final status = await platform.storageStatus(requestPersistence: true);
      if (mounted) setState(() => _storageStatus = status);
    } on Object {
      if (mounted) setState(() => _storageStatus = '保存状態を確認できませんでした。');
    }
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final db = await (debugOpenBirdLogDatabase ?? BirdLogDatabase.open)();
      final trips = await db.loadTrips();
      final records = await db.loadRecords();
      final birdLists = await db.loadBirdLists();
      final stationarySessions = await db.loadStationarySessions();
      if (!mounted) {
        await db.close();
        return;
      }
      setState(() {
        _prefs = prefs;
        _db = db;
        _trips = trips;
        _records = records;
        _stationarySessions = stationarySessions;
        _birdLists = birdLists;
        _currentTripId = prefs.getString(_currentTripKey) ?? '';
        _view = _parseView(prefs.getString(_appViewKey));
        if (_currentTrip == null && _view == AppView.trip) {
          _view = AppView.cover;
          _currentTripId = '';
        }
        _syncTripControllers();
        _loading = false;
      });
      _resumeLocation();
    } on Object {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError =
            '保存領域を開けませんでした。他のタブでこのアプリを開いている場合は閉じてください。ブラウザのサイトデータ設定も確認してください。';
      });
    }
  }

  AppView _parseView(String? value) {
    return AppView.values.firstWhere(
      (view) => view.name == value,
      orElse: () => AppView.cover,
    );
  }

  Future<bool> _save() async {
    final prefs = _prefs;
    final db = _db;
    if (prefs == null || db == null) return false;
    final trips = _trips.map((t) => BirdTrip.fromJson(t.toJson())).toList();
    final records = _records
        .map((r) => BirdRecord.fromJson(r.toJson()))
        .toList();
    final stationarySessions = _stationarySessions
        .map((s) => StationarySession.fromRow(s.toRow()))
        .toList();
    final birdLists = _birdLists.map(
      (key, value) => MapEntry(key, value.toList()),
    );
    final pending = _saveQueue.then((_) async {
      await db.saveSnapshot(
        trips: trips,
        records: records,
        birdLists: birdLists,
        stationarySessions: stationarySessions,
      );
      await prefs.setString(_currentTripKey, _currentTripId);
      await prefs.setString(_appViewKey, _view.name);
    });
    _saveQueue = pending.catchError((Object _) {});
    try {
      await pending;
      return true;
    } on Object {
      _showMessage('保存に失敗しました。画面の内容はまだ端末に保存されていません。保存領域を確認してください。');
      return false;
    }
  }

  void _syncTripControllers() {
    final trip = _currentTrip;
    _tripTitleController.text = trip?.title ?? '';
    _setTimeControllers(
      trip?.startTime ?? '',
      _startHourController,
      _startMinuteController,
    );
    _setTimeControllers(
      trip?.endTime ?? '',
      _endHourController,
      _endMinuteController,
    );
  }

  void _setTimeControllers(
    String time,
    TextEditingController hour,
    TextEditingController minute,
  ) {
    final match = RegExp(r'^(\d{1,2})(?::(\d{1,2}))?$').firstMatch(time);
    if (match == null) {
      hour.clear();
      minute.clear();
      return;
    }
    hour.text = _two(int.tryParse(match.group(1) ?? '') ?? 0);
    minute.text = _two(int.tryParse(match.group(2) ?? '') ?? 0);
  }

  void _setView(AppView view) {
    if (view != AppView.trip) _stopAutoLocation();
    setState(() => _view = view);
    _resumeLocation();
    _save();
  }

  void _startNewTrip() {
    final now = DateTime.now();
    final id = 'trip-${now.microsecondsSinceEpoch}';
    setState(() {
      _trips.insert(0, BirdTrip(id: id, startedAt: now));
      _currentTripId = id;
      _birdLists[id] = [];
      _view = AppView.trip;
      _tab = TripTab.record;
      _syncTripControllers();
      _resetCountInputs();
    });
    _resumeLocation();
    _save();
  }

  void _openTrip(String id) {
    if (_stationarySessions.any((s) => s.tripId == id && s.endedAt == null)) {
      _stopAutoLocation();
    }
    setState(() {
      _currentTripId = id;
      _view = AppView.trip;
      _tab = TripTab.edit;
      _syncTripControllers();
      _resetCountInputs();
    });
    _resumeLocation();
    _save();
  }

  Future<void> _confirmDeleteTrip(BirdTrip trip) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('トリップを削除しますか？'),
        content: const Text('このトリップの記録と、よく見る鳥の一覧も削除されます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) _deleteTrip(trip);
  }

  void _deleteTrip(BirdTrip trip) {
    final tripIndex = _trips.indexWhere((item) => item.id == trip.id);
    final deletedRecords = _records
        .where((record) => record.tripId == trip.id)
        .toList();
    final deletedStationary = _stationarySessions
        .where((s) => s.tripId == trip.id)
        .toList();
    for (final session in deletedStationary) {
      session.endedAt ??= DateTime.now();
    }
    _stationarySessions.removeWhere((s) => s.tripId == trip.id);
    final deletedBirds = List<String>.from(_birdLists[trip.id] ?? const []);
    setState(() {
      _trips.removeWhere((item) => item.id == trip.id);
      _records.removeWhere((record) => record.tripId == trip.id);
      _birdLists.remove(trip.id);
      if (_currentTripId == trip.id) {
        _stopAutoLocation();
        _currentTripId = '';
        _view = AppView.cover;
      }
    });
    _save();
    _showUndoMessage('トリップを削除しました', () {
      setState(() {
        _trips.insert(tripIndex.clamp(0, _trips.length), trip);
        _records.addAll(deletedRecords);
        _stationarySessions.addAll(deletedStationary);
        _birdLists[trip.id] = deletedBirds;
      });
      _save();
    });
  }

  void _updateTripField(String field, String value) {
    final trip = _currentTrip;
    if (trip == null) return;
    setState(() {
      switch (field) {
        case 'title':
          trip.title = value;
        case 'start':
          trip.startTime = value;
        case 'end':
          trip.endTime = value;
      }
    });
    _save();
  }

  void _updateTripTimeFromParts({
    required String field,
    required TextEditingController hourController,
    required TextEditingController minuteController,
  }) {
    final hour = int.tryParse(hourController.text)?.clamp(0, 23) ?? 0;
    final minute = int.tryParse(minuteController.text)?.clamp(0, 59) ?? 0;
    _updateTripField(field, '${_two(hour)}:${_two(minute)}');
  }

  Future<void> _showTripTimePicker({
    required String title,
    required String field,
    required TextEditingController hourController,
    required TextEditingController minuteController,
  }) async {
    var selectedHour =
        int.tryParse(hourController.text)?.clamp(0, 23) ?? TimeOfDay.now().hour;
    var selectedMinute =
        int.tryParse(minuteController.text)?.clamp(0, 59) ??
        TimeOfDay.now().minute;
    final hourScrollController = FixedExtentScrollController(
      initialItem: selectedHour,
    );
    final minuteScrollController = FixedExtentScrollController(
      initialItem: selectedMinute,
    );

    final result = await showModalBottomSheet<TimeOfDay>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        '${_two(selectedHour)}:${_two(selectedMinute)}',
                        style: Theme.of(context).textTheme.displaySmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 180,
                      child: Row(
                        children: [
                          Expanded(
                            child: _TimeWheelPicker(
                              label: '時',
                              itemCount: 24,
                              controller: hourScrollController,
                              onSelectedItemChanged: (value) {
                                setSheetState(() => selectedHour = value);
                              },
                            ),
                          ),
                          Expanded(
                            child: _TimeWheelPicker(
                              label: '分',
                              itemCount: 60,
                              controller: minuteScrollController,
                              onSelectedItemChanged: (value) {
                                setSheetState(() => selectedMinute = value);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => Navigator.pop(
                        context,
                        TimeOfDay(hour: selectedHour, minute: selectedMinute),
                      ),
                      child: const Text('決定'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    hourScrollController.dispose();
    minuteScrollController.dispose();

    if (result == null) return;
    hourController.text = _two(result.hour);
    minuteController.text = _two(result.minute);
    _updateTripTimeFromParts(
      field: field,
      hourController: hourController,
      minuteController: minuteController,
    );
  }

  void _addBirdButton() {
    final bird = _newBirdController.text.trim();
    if (bird.isEmpty) return;
    setState(() {
      final list = _birdList;
      if (!list.contains(bird)) list.add(bird);
      _birdLists[_currentTripId] = list;
      _newBirdController.clear();
    });
    _save();
  }

  void _removeBirdButton(String bird) {
    setState(() => _birdLists[_currentTripId] = _birdList..remove(bird));
    _save();
  }

  void _addNumber(int number) {
    setState(() {
      if (_countAddMode) {
        _count += number;
      } else if (number < 10) {
        _count = number;
      } else {
        _count = number;
        _countAddMode = true;
      }
    });
  }

  void _resetCountInputs() {
    setState(() {
      _speciesOnlyMode = false;
      _count = 1;
      _countAddMode = false;
      _approx = '';
      _details.clear();
      _commentController.clear();
    });
  }

  Future<void> _saveRecord() async {
    if (_savingRecord || _changingStationary) return;
    final species = _speciesController.text.trim();
    final tripId = _currentTripId;
    if (_currentTrip == null) return;
    if (species.isEmpty) {
      _showMessage('種名を入力してください');
      return;
    }
    final speciesOnly = _speciesOnlyMode;
    final stationary = speciesOnly ? null : _activeStationary;
    if (!speciesOnly && stationary == null) _startAutoLocation();
    setState(() => _savingRecord = true);
    try {
      final position =
          !speciesOnly &&
              stationary == null &&
              _isFreshAccuratePosition(_currentLocation)
          ? _currentLocation
          : null;
      final now = DateTime.now();
      final details = _detailCodes.where(_details.contains).join();
      final record = BirdRecord(
        id: 'record-${now.microsecondsSinceEpoch}',
        tripId: tripId,
        species: species,
        speciesOnly: speciesOnly,
        count: speciesOnly ? '' : '$_count$_approx$details',
        time: speciesOnly ? null : now,
        latitude: stationary?.latitude ?? position?.latitude,
        longitude: stationary?.longitude ?? position?.longitude,
        locationAccuracy: stationary?.accuracy ?? position?.accuracy,
        locationTime: stationary?.locationTime ?? position?.timestamp.toLocal(),
        stationarySessionId: stationary?.id,
        comment: speciesOnly ? '' : _commentController.text.trim(),
      );
      setState(() {
        _records.add(record);
        _speciesController.clear();
        _resetCountInputs();
      });
      final saved = await _save();
      if (!saved) return;
      if (!mounted || _view != AppView.trip || _currentTripId != tripId) return;
      final message = speciesOnly
          ? '種のみ記録しました'
          : record.latitude == null
          ? '位置情報なしで保存しました。測位できたら位置の追加を確認できます'
          : '記録しました';
      if ((_birdLists[tripId] ?? const <String>[]).contains(species)) {
        _showMessage(message);
      } else {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              duration: const Duration(seconds: 10),
              showCloseIcon: true,
              content: Text('$message\n「$species」をよく見る鳥に追加しますか？'),
              action: SnackBarAction(
                label: '追加する',
                onPressed: () {
                  if (!mounted || !_trips.any((trip) => trip.id == tripId)) {
                    return;
                  }
                  setState(() {
                    final list = _birdLists.putIfAbsent(tripId, () => []);
                    if (!list.contains(species)) list.add(species);
                  });
                  unawaited(_save());
                },
              ),
            ),
          );
      }
      if (!speciesOnly && stationary == null && record.latitude == null) {
        _waitForSavedRecordLocation(record);
      }
    } finally {
      if (mounted) setState(() => _savingRecord = false);
    }
  }

  void _waitForSavedRecordLocation(BirdRecord record) {
    if (!_autoLocationActive) return;
    _recordLocationTimers[record.id] = Timer(_recordLocationWaitLimit, () {
      _recordLocationTimers.remove(record.id);
      final candidate = _locationCandidates.remove(record.id);
      if (candidate != null) _offerRecordLocation(record, candidate);
    });
    final current = _currentLocation;
    if (current != null &&
        _validRecentPosition(current) &&
        !current.timestamp.isBefore(record.time!)) {
      _considerSavedRecordLocations(current);
    }
  }

  bool _validRecentPosition(Position position) {
    final age = DateTime.now().difference(position.timestamp.toLocal());
    return position.latitude.isFinite &&
        position.latitude.abs() <= 90 &&
        position.longitude.isFinite &&
        position.longitude.abs() <= 180 &&
        position.accuracy.isFinite &&
        position.accuracy >= 0 &&
        age >= Duration.zero &&
        age <= _recordLocationMaxAge;
  }

  void _considerSavedRecordLocations(Position position) {
    if (!_validRecentPosition(position)) return;
    for (final id in _recordLocationTimers.keys.toList()) {
      final record = _records.where((r) => r.id == id).firstOrNull;
      if (record == null || record.latitude != null || record.speciesOnly) {
        _cancelRecordLocation(id);
        continue;
      }
      if (position.timestamp.isBefore(record.time!)) continue;
      final best = _locationCandidates[id];
      if (best == null || position.accuracy < best.accuracy) {
        _locationCandidates[id] = position;
      }
      if (position.accuracy <= _locationTargetAccuracy) {
        _cancelRecordLocation(id);
        _offerRecordLocation(record, position);
      }
    }
  }

  void _cancelRecordLocation(String id) {
    _recordLocationTimers.remove(id)?.cancel();
    _locationCandidates.remove(id);
  }

  void _offerRecordLocation(BirdRecord record, Position position) {
    if (!mounted ||
        !_records.contains(record) ||
        record.latitude != null ||
        _view != AppView.trip ||
        _currentTripId != record.tripId) {
      return;
    }
    final offeredSnapshot = record.toJson().toString();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 15),
        showCloseIcon: true,
        content: Text(
          '${record.species}（${_clockText(record.time!)}）を保存済み。'
          '保存後の測位位置（±${position.accuracy.toStringAsFixed(0)}m）が観察地点なら追加してください。',
        ),
        action: SnackBarAction(
          label: '位置を追加',
          onPressed: () {
            if (!mounted ||
                !_records.contains(record) ||
                record.latitude != null ||
                record.speciesOnly ||
                _view != AppView.trip ||
                _currentTripId != record.tripId ||
                record.toJson().toString() != offeredSnapshot) {
              return;
            }
            setState(() {
              record.latitude = position.latitude;
              record.longitude = position.longitude;
              record.locationAccuracy = position.accuracy;
              record.locationTime = position.timestamp.toLocal();
            });
            unawaited(_save());
          },
        ),
      ),
    );
  }

  Future<void> _toggleStationary(bool enabled) async {
    if (_changingStationary || _savingRecord) return;
    if (!enabled) {
      setState(() {
        _activeStationary?.endedAt = DateTime.now();
        _locationStatus = '定点モードを終了しました';
        _currentLocation = null;
        _currentLocationUpdatedAt = null;
      });
      await _save();
      _resumeLocation();
      return;
    }
    final tripId = _currentTripId;
    final startedAt = DateTime.now();
    setState(() => _changingStationary = true);
    try {
      await _stopAutoLocation();
      if (!mounted || tripId != _currentTripId || _view != AppView.trip) return;
      _currentLocation = null;
      final pending = _positionForRecord();
      _startAutoLocation();
      final position = await pending;
      await _stopAutoLocation();
      if (!mounted || tripId != _currentTripId || _view != AppView.trip) return;
      if (position == null ||
          !position.latitude.isFinite ||
          !position.longitude.isFinite ||
          position.latitude.abs() > 90 ||
          position.longitude.abs() > 180 ||
          position.timestamp.isBefore(startedAt) ||
          !position.accuracy.isFinite ||
          position.accuracy < 0 ||
          DateTime.now().difference(position.timestamp).abs() >
              const Duration(seconds: 30)) {
        _showMessage('位置を取得できなかったため、定点モードを開始できませんでした');
        return;
      }
      setState(() {
        _stationarySessions.add(
          StationarySession(
            id: 'stationary-${startedAt.microsecondsSinceEpoch}',
            tripId: tripId,
            startedAt: startedAt,
            latitude: position.latitude,
            longitude: position.longitude,
            accuracy: position.accuracy,
            locationTime: position.timestamp.toLocal(),
          ),
        );
        _currentLocation = position;
        _currentLocationUpdatedAt = position.timestamp.toLocal();
        _locationStatus = '定点モード：測位を一時停止中（開始時の位置を使用）';
        _refreshingLocation = false;
      });
      await _save();
    } finally {
      if (mounted) setState(() => _changingStationary = false);
    }
  }

  Future<Position?> _positionForRecord() {
    final current = _currentLocation;
    if (_isFreshAccuratePosition(current)) return Future.value(current);

    final pending = Completer<Position?>();
    _pendingRecordPosition = pending;
    _pendingRecordBestPosition =
        current != null && _validRecentPosition(current) ? current : null;
    _pendingRecordHasNewPosition = false;
    _recordLocationWaitTimer?.cancel();
    _recordLocationWaitTimer = Timer(
      _recordLocationWaitLimit,
      () => _completePendingRecordPosition(_pendingRecordBestPosition),
    );
    return pending.future;
  }

  bool _isFreshAccuratePosition(Position? position) {
    if (position == null ||
        !_validRecentPosition(position) ||
        position.accuracy > _locationTargetAccuracy) {
      return false;
    }
    final age = DateTime.now().difference(position.timestamp.toLocal());
    return age >= Duration.zero && age <= _recordLocationMaxAge;
  }

  void _completePendingRecordPosition(Position? position) {
    _recordLocationWaitTimer?.cancel();
    _recordLocationWaitTimer = null;
    final pending = _pendingRecordPosition;
    _pendingRecordPosition = null;
    _pendingRecordBestPosition = null;
    _pendingRecordHasNewPosition = false;
    if (pending != null && !pending.isCompleted) pending.complete(position);
  }

  /// トリップを開いたとき・復帰時・現在地の手動更新時に測位を開始する。
  /// 観察中は位置情報ストリームを維持し、GPS が十分に捕捉されるまで
  /// 単発測位をやり直さずに待つ。
  void _startAutoLocation() {
    if (_activeStationary != null) return;
    _autoLocationActive = true;
    if (_locationSubscription == null) {
      unawaited(_startLocationStream());
    }
  }

  Future<void> _stopAutoLocation() async {
    for (final timer in _recordLocationTimers.values) {
      timer.cancel();
    }
    _recordLocationTimers.clear();
    _locationCandidates.clear();
    _locationGeneration++;
    _autoLocationActive = false;
    _currentLocation = null;
    _currentLocationUpdatedAt = null;
    _refreshingLocation = false;
    _startingLocationStream = false;
    _completePendingRecordPosition(null);
    final subscription = _locationSubscription;
    _locationSubscription = null;
    if (subscription != null) await subscription.cancel();
  }

  // 手動更新ボタンからも連続測位を開始する。
  void _refreshCurrentLocation() => _startAutoLocation();

  Future<void> _startLocationStream() async {
    if (_startingLocationStream ||
        !_autoLocationActive ||
        _activeStationary != null) {
      return;
    }
    _startingLocationStream = true;
    final generation = _locationGeneration;
    bool isCurrent() =>
        mounted &&
        _autoLocationActive &&
        _activeStationary == null &&
        generation == _locationGeneration;
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!isCurrent()) return;
      if (!serviceEnabled) {
        _showLocationUnavailable();
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (!isCurrent()) return;
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (!isCurrent()) return;
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _showLocationUnavailable();
        return;
      }
      if (!isCurrent()) return;
      setState(() {
        _refreshingLocation = true;
        _locationStatus = _currentLocation == null ? '現在地を取得中です' : '現在地を更新中です';
      });
      _locationSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              distanceFilter: 0,
            ),
          ).listen(
            (position) {
              if (isCurrent()) _onLocationUpdate(position);
            },
            onError: (Object error, StackTrace stackTrace) {
              if (isCurrent()) _onLocationError(error, stackTrace);
            },
          );
    } on Exception {
      if (isCurrent()) _showLocationUnavailable();
    } finally {
      if (generation == _locationGeneration) _startingLocationStream = false;
    }
  }

  void _onLocationUpdate(Position position) {
    if (!mounted || !_autoLocationActive || !_validRecentPosition(position)) {
      return;
    }
    _considerSavedRecordLocations(position);
    if (_pendingRecordPosition != null) {
      final best = _pendingRecordBestPosition;
      if (!_pendingRecordHasNewPosition ||
          best == null ||
          position.accuracy < best.accuracy) {
        _pendingRecordBestPosition = position;
      }
      _pendingRecordHasNewPosition = true;
      if (position.accuracy <= _locationTargetAccuracy) {
        _completePendingRecordPosition(position);
      }
    }
    final withinTarget = position.accuracy <= _locationTargetAccuracy;
    setState(() {
      _currentLocation = position;
      _currentLocationUpdatedAt = position.timestamp.toLocal();
      _refreshingLocation = !withinTarget;
      final accuracy = '±${position.accuracy.toStringAsFixed(0)}m';
      _locationStatus = withinTarget
          ? '現在地を取得しました（$accuracy・高精度測位を継続中）'
          : '精度を改善中です（$accuracy）';
    });
  }

  void _onLocationError(Object error, StackTrace stackTrace) {
    _showLocationUnavailable();
  }

  void _showLocationUnavailable([String? message]) {
    _completePendingRecordPosition(_pendingRecordBestPosition);
    if (!mounted || !_autoLocationActive) return;
    setState(() {
      _refreshingLocation = false;
      _locationStatus =
          message ??
          (_currentLocation == null ? '現在地を取得できませんでした' : '現在地を更新できませんでした');
    });
  }

  Future<void> _editRecord(BirdRecord record) async {
    _cancelRecordLocation(record.id);
    final result = await showDialog<BirdRecord>(
      context: context,
      builder: (context) => _EditRecordDialog(record: record),
    );
    if (result == null) return;
    setState(() {
      if (record.latitude != result.latitude ||
          record.longitude != result.longitude) {
        record.placeName = '';
      }
      record.species = result.species;
      record.count = result.count;
      record.time = result.time;
      record.latitude = result.latitude;
      record.longitude = result.longitude;
      record.locationAccuracy = result.locationAccuracy;
      record.locationTime = result.locationTime;
      record.comment = result.comment;
    });
    _save();
  }

  Future<void> _editRecordFromMap(BirdRecord record) async {
    setState(() => _tab = TripTab.edit);
    await _editRecord(record);
  }

  Future<void> _confirmDeleteRecord(BirdRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('記録を削除しますか？'),
        content: Text('${record.species} ${record.count} の記録を削除します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) _deleteRecord(record);
  }

  void _deleteRecord(BirdRecord record) {
    final recordIndex = _records.indexWhere((item) => item.id == record.id);
    setState(() => _records.removeWhere((item) => item.id == record.id));
    _save();
    _showUndoMessage('記録を削除しました', () {
      setState(
        () => _records.insert(recordIndex.clamp(0, _records.length), record),
      );
      _save();
    });
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _showMessage('コピーしました');
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showUndoMessage(String message, VoidCallback onUndo) {
    if (!mounted) return;
    final key = GlobalKey();
    _undoSnackBarKey = key;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: key,
          duration: const Duration(seconds: 5),
          persist: false,
          content: Text(message),
          action: SnackBarAction(label: '元に戻す', onPressed: onUndo),
        ),
      );
  }

  void _dismissUndoMessageOutside(PointerDownEvent event) {
    final box = _undoSnackBarKey?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final bounds = box.localToGlobal(Offset.zero) & box.size;
    if (!bounds.contains(event.position)) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
  }

  String _dateText(DateTime date) =>
      '${date.year}/${_two(date.month)}/${_two(date.day)}';

  String _timeText(DateTime date) => '${_two(date.hour)}:${_two(date.minute)}';

  String _two(int value) => value.toString().padLeft(2, '0');

  String _recordSubtitle(BirdRecord record) {
    if (record.speciesOnly) return speciesOnlyHeading;
    final time = _timeText(record.time!);
    if (record.latitude == null || record.longitude == null) return time;
    return '$time  ${record.latitude!.toStringAsFixed(6)}, ${record.longitude!.toStringAsFixed(6)}';
  }

  String _tripTitle(BirdTrip trip) {
    final title = trip.title.trim();
    return title.isEmpty
        ? _dateText(trip.startedAt)
        : '${_dateText(trip.startedAt)}  $title';
  }

  String _locationText() {
    final fixed = _activeStationary;
    if (fixed != null) {
      return '緯度 ${fixed.latitude.toStringAsFixed(6)} / 経度 ${fixed.longitude.toStringAsFixed(6)} / 精度 ±${fixed.accuracy.toStringAsFixed(0)}m';
    }
    final location = _currentLocation;
    if (location == null) return '緯度・経度: --';
    return '緯度 ${location.latitude.toStringAsFixed(6)} / 経度 ${location.longitude.toStringAsFixed(6)} / 精度 ±${location.accuracy.toStringAsFixed(0)}m';
  }

  String _locationUpdatedText() {
    final updatedAt =
        _activeStationary?.locationTime ?? _currentLocationUpdatedAt;
    return updatedAt == null ? '更新: --' : '更新: ${_timeText(updatedAt)}';
  }

  int _numericCount(String count) {
    final match = RegExp(r'\d+').firstMatch(count);
    return int.tryParse(match?.group(0) ?? '') ?? 0;
  }

  /// 第8版にない入力名は、照合できた種の後にまとめて表示する。
  List<MapEntry<String, int>> _orderedSpeciesEntries(Map<String, int> totals) {
    final matched = <MapEntry<String, int>>[];
    final unmatched = <MapEntry<String, int>>[];
    for (final entry in totals.entries) {
      (_eighthEditionSpeciesRanks.containsKey(entry.key) ? matched : unmatched)
          .add(entry);
    }
    matched.sort(
      (a, b) => _eighthEditionSpeciesRanks[a.key]!.compareTo(
        _eighthEditionSpeciesRanks[b.key]!,
      ),
    );
    unmatched.sort((a, b) => a.key.compareTo(b.key));
    return [
      ...matched,
      if (matched.isNotEmpty && unmatched.isNotEmpty) const MapEntry('', 0),
      ...unmatched,
    ];
  }

  String _tripExportHeader() {
    final trip = _currentTrip;
    if (trip == null) return '';
    final timeRange = [
      trip.startTime.trim(),
      trip.endTime.trim(),
    ].where((value) => value.isNotEmpty).join('-');
    return [
      _dateText(trip.startedAt),
      if (timeRange.isNotEmpty) timeRange,
      if (trip.title.trim().isNotEmpty) trip.title.trim(),
    ].join(' ');
  }

  List<String> get _speciesOnlyNames => _speciesInEighthEditionOrder(
    _visibleRecords.where((r) => r.speciesOnly).map((r) => r.species),
  );

  String get _speciesOnlyText => _speciesOnlyNames.isEmpty
      ? ''
      : [speciesOnlyHeading, ..._speciesOnlyNames].join('\n');

  String _withSpeciesOnly(String normal) =>
      [normal, _speciesOnlyText].where((text) => text.isNotEmpty).join('\n\n');

  String _summaryText() {
    final totals = <String, int>{};
    final countedSpecies = <String>{};
    for (final record in _visibleRecords) {
      totals.putIfAbsent(record.species, () => 0);
      if (!record.speciesOnly) {
        countedSpecies.add(record.species);
        totals[record.species] =
            totals[record.species]! + _numericCount(record.count);
      }
    }
    if (totals.isEmpty) return '記録はまだありません';
    final body = _orderedSpeciesEntries(totals)
        .map((entry) {
          if (entry.key.isEmpty) return '';
          if (!countedSpecies.contains(entry.key)) return entry.key;
          final note = _speciesOnlyNames.contains(entry.key)
              ? '（種のみの記録あり）'
              : '';
          return '${entry.key} ${entry.value}$note';
        })
        .join('\n');
    final header = _tripExportHeader();
    return header.isEmpty ? body : '$header\n$body';
  }

  String _placeSummaryText() {
    final totalsByPlace = <String, Map<String, int>>{};
    for (final record in _visibleRecords.where((r) => !r.speciesOnly)) {
      final place = record.placeName.trim().isEmpty
          ? '地名未取得'
          : record.placeName.trim();
      final totals = totalsByPlace.putIfAbsent(place, () => {});
      totals[record.species] =
          (totals[record.species] ?? 0) + _numericCount(record.count);
    }
    if (totalsByPlace.isEmpty) {
      return _speciesOnlyText.isEmpty ? '記録はまだありません' : _speciesOnlyText;
    }
    final places = totalsByPlace.keys.toList()
      ..sort((a, b) {
        if (a == '地名未取得') return 1;
        if (b == '地名未取得') return -1;
        return a.compareTo(b);
      });
    return _withSpeciesOnly(
      places
          .map((place) {
            final entries = _orderedSpeciesEntries(totalsByPlace[place]!);
            return [
              place,
              ...entries.map(
                (entry) =>
                    entry.key.isEmpty ? '' : '${entry.key} ${entry.value}',
              ),
            ].join('\n');
          })
          .join('\n\n'),
    );
  }

  String _recordExportText({required bool withLocation}) {
    final records = _visibleRecords.where((r) => !r.speciesOnly).toList()
      ..sort((a, b) => a.time!.compareTo(b.time!));
    if (records.isEmpty) {
      return _speciesOnlyText.isEmpty ? '記録はまだありません' : _speciesOnlyText;
    }
    return _withSpeciesOnly(
      records
          .map((record) {
            final hasLocation =
                record.latitude != null && record.longitude != null;
            return [
              _timeText(record.time!),
              record.species,
              if (withLocation && !hasLocation) '位置情報null',
              record.count,
              if (withLocation && hasLocation) ...[
                record.latitude!.toStringAsFixed(6),
                record.longitude!.toStringAsFixed(6),
                if (record.locationAccuracy != null)
                  '±${record.locationAccuracy!.toStringAsFixed(0)}m',
                if (record.locationTime != null)
                  _timeText(record.locationTime!),
              ],
            ].join('\t');
          })
          .join('\n'),
    );
  }

  List<BirdRecord> _displayRecords() {
    final records = _visibleRecords.where((r) => !r.speciesOnly).toList()
      ..sort((a, b) => a.time!.compareTo(b.time!));
    if (_newestFirst) records.sort((a, b) => b.time!.compareTo(a.time!));
    return records;
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_loadError!),
          ),
        ),
      );
    }
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _dismissUndoMessageOutside,
      child: switch (_view) {
        AppView.cover => _buildCover(),
        AppView.past => _buildPast(),
        AppView.trip => _buildTrip(),
      },
    );
  }

  Widget _buildCover() {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'birdlog_app_webversion',
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  FilledButton(
                    onPressed: _startNewTrip,
                    child: const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('新しく始める'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => _setView(AppView.past),
                    child: const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('過去の記録を見る'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPast() {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => _setView(AppView.cover),
        ),
        title: const Text('過去の記録'),
      ),
      body: SafeArea(
        child: _trips.isEmpty
            ? const Center(child: Text('過去の記録はまだありません'))
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _trips.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final trip = _trips[index];
                  final timeRange = [
                    trip.startTime,
                    trip.endTime,
                  ].where((value) => value.isNotEmpty).join('〜');
                  return Card(
                    child: ListTile(
                      title: Text(_tripTitle(trip)),
                      subtitle: timeRange.isEmpty ? null : Text(timeRange),
                      onTap: () => _openTrip(trip.id),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _confirmDeleteTrip(trip),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget _buildTrip() {
    final trip = _currentTrip;
    if (trip == null) return _buildCover();
    return Listener(
      onPointerDown: (_) => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.home_outlined),
            onPressed: () => _setView(AppView.cover),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _dateText(trip.startedAt),
                style: const TextStyle(fontSize: 12),
              ),
              TextField(
                controller: _tripTitleController,
                decoration: const InputDecoration(
                  hintText: '観察場所など',
                  isDense: true,
                  border: InputBorder.none,
                ),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
                onChanged: (value) => _updateTripField('title', value),
              ),
            ],
          ),
          actions: [
            _TripTimeField(
              label: '開始',
              hourController: _startHourController,
              minuteController: _startMinuteController,
              onPick: () => _showTripTimePicker(
                title: '開始時刻',
                field: 'start',
                hourController: _startHourController,
                minuteController: _startMinuteController,
              ),
            ),
            const Center(child: Text('〜')),
            _TripTimeField(
              label: '終了',
              hourController: _endHourController,
              minuteController: _endMinuteController,
              onPick: () => _showTripTimePicker(
                title: '終了時刻',
                field: 'end',
                hourController: _endHourController,
                minuteController: _endMinuteController,
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: SafeArea(
          child: IndexedStack(
            index: _tab.index,
            children: [
              _buildRecordTab(),
              _buildEditTab(),
              _buildLogsTab(),
              // 非表示中の IndexedStack 内で地図を初期化すると、iOS では
              // 0 サイズの状態でタイル読み込みが止まることがある。マップタブを
              // 選んだときだけ生成し、表示可能なサイズで初期化する。
              if (_tab == TripTab.map)
                _MapTab(
                  speciesOnlyText: _speciesOnlyText,
                  records: _visibleRecords
                      .where(
                        (record) =>
                            record.latitude != null && record.longitude != null,
                      )
                      .toList(),
                  stationarySessions: _stationarySessions
                      .where((s) => s.tripId == _currentTripId)
                      .toList(),
                  currentLocation: _activeStationary == null
                      ? _currentLocation
                      : null,
                  refreshingLocation: _refreshingLocation,
                  onRefreshLocation: _activeStationary == null
                      ? _refreshCurrentLocation
                      : null,
                  onEditRecord: _editRecordFromMap,
                )
              else
                const SizedBox.expand(),
              _buildSettingsTab(),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_tab == TripTab.record)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: _SavePanel(
                    speciesOnly: _speciesOnlyMode,
                    countText:
                        '$_count$_approx${_detailCodes.where(_details.contains).join()}',
                    onMinus: () =>
                        setState(() => _count = (_count - 1).clamp(1, 999999)),
                    onPlus: () => setState(() => _count++),
                    onReset: _resetCountInputs,
                    onSave: _savingRecord || _changingStationary
                        ? null
                        : _saveRecord,
                    saving: _savingRecord,
                  ),
                ),
              NavigationBar(
                selectedIndex: _tab.index,
                onDestinationSelected: (index) =>
                    setState(() => _tab = TripTab.values[index]),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.edit_note),
                    label: '記録',
                  ),
                  NavigationDestination(icon: Icon(Icons.edit), label: '編集'),
                  NavigationDestination(
                    icon: Icon(Icons.summarize_outlined),
                    label: '集計',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.map_outlined),
                    label: 'マップ',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.settings_outlined),
                    label: '設定',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecordTab() {
    final colorScheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _speciesController,
                decoration: const InputDecoration(
                  hintText: '種名',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _speciesController,
              builder: (context, value, _) {
                final text = value.text.trim();
                final selected = text == 'sp.' || text.endsWith(' sp.');
                return Semantics(
                  selected: selected,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: selected ? colorScheme.primary : null,
                      foregroundColor: selected ? colorScheme.onPrimary : null,
                    ),
                    onPressed: () {
                      _speciesController.text = selected
                          ? (text == 'sp.'
                                ? ''
                                : text.substring(0, text.length - 4))
                          : (text.isEmpty ? 'sp.' : '$text sp.');
                    },
                    child: const Text('sp.'),
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _speciesController,
          builder: (context, value, _) {
            return Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final bird in _birdList)
                  ChoiceChip(
                    label: Text(bird),
                    selected: value.text == bird,
                    showCheckmark: false,
                    selectedColor: colorScheme.primary,
                    labelStyle: TextStyle(
                      color: value.text == bird ? colorScheme.onPrimary : null,
                    ),
                    onSelected: (_) {
                      _speciesController.text = value.text == bird ? '' : bird;
                    },
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 2.25,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          children: [
            for (final number in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 50, 100])
              FilledButton.tonal(
                onPressed: () => _addNumber(number),
                style: FilledButton.styleFrom(
                  backgroundColor: number <= 10 && _count == number
                      ? colorScheme.primary
                      : null,
                  foregroundColor: number <= 10 && _count == number
                      ? colorScheme.onPrimary
                      : null,
                ),
                child: Text('$number'),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final symbol in ['+', '-', '±'])
              FilterChip(
                label: Text(symbol),
                selected: _approx == symbol,
                showCheckmark: false,
                selectedColor: colorScheme.primary,
                labelStyle: TextStyle(
                  color: _approx == symbol ? colorScheme.onPrimary : null,
                ),
                onSelected: (_) =>
                    setState(() => _approx = _approx == symbol ? '' : symbol),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final detail in _detailCodes)
              FilterChip(
                label: Text(detail),
                selected: _details.contains(detail),
                showCheckmark: false,
                selectedColor: colorScheme.primary,
                labelStyle: TextStyle(
                  color: _details.contains(detail)
                      ? colorScheme.onPrimary
                      : null,
                ),
                onSelected: (_) {
                  setState(() {
                    if (_details.contains(detail)) {
                      _details.remove(detail);
                    } else {
                      _details.add(detail);
                    }
                  });
                },
              ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _commentController,
          minLines: 2,
          maxLines: 4,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => FocusManager.instance.primaryFocus?.unfocus(),
          onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'コメント',
            hintText: '観察時の状況などを自由に記入',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 10),
        SwitchListTile(
          title: const Text('定点モード'),
          subtitle: Text(
            _changingStationary
                ? '定点の位置を取得中です（最大30秒）'
                : _activeStationary != null
                ? 'オン：開始時の位置で記録します'
                : 'オンにした時の位置に固定します',
          ),
          value: _activeStationary != null,
          onChanged: _savingRecord || _changingStationary
              ? null
              : _toggleStationary,
        ),
        SwitchListTile(
          key: const Key('species-only-mode'),
          title: const Text('位置情報・見た時間・数を記録しない'),
          subtitle: const Text('種のみ記録します。1回記録するとオフになります。'),
          value: _speciesOnlyMode,
          onChanged: _savingRecord || _changingStationary
              ? null
              : (value) => setState(() => _speciesOnlyMode = value),
        ),
        _LocationPanel(
          status: _activeStationary != null
              ? '定点モード：測位を一時停止中（開始時の位置を使用）'
              : _locationStatus,
          locationText: _locationText(),
          updatedText: _locationUpdatedText(),
          refreshing: _refreshingLocation,
          onRefresh: _activeStationary == null ? _refreshCurrentLocation : null,
        ),
        const SizedBox(height: 10),
      ],
    );
  }

  Future<void> _fetchMissingPlaceNames() async {
    if (_fetchingPlaceNames) return;
    final pending = _visibleRecords
        .where(
          (record) =>
              record.placeName.trim().isEmpty &&
              record.latitude != null &&
              record.longitude != null,
        )
        .toList();
    if (pending.isEmpty) {
      _showMessage('字名を取得できる未取得の記録はありません（位置情報が必要です）');
      return;
    }
    setState(() {
      _fetchingPlaceNames = true;
      _placeNamesProcessed = 0;
      _placeNamesTotal = pending.length;
    });
    var acquired = 0;
    var failed = 0;
    try {
      for (final record in pending) {
        if (!mounted) return;
        if (!_records.contains(record) || record.placeName.trim().isNotEmpty) {
          continue;
        }
        final latitude = record.latitude;
        final longitude = record.longitude;
        if (latitude == null || longitude == null) continue;
        try {
          final place = await platform
              .placeName(latitude, longitude)
              .timeout(const Duration(seconds: 15));
          if (!mounted) return;
          // 取得中に削除・位置編集された記録へ古い地名を書き込まない。
          if (!_records.contains(record) ||
              record.latitude != latitude ||
              record.longitude != longitude ||
              record.placeName.trim().isNotEmpty) {
            continue;
          }
          if (place.isEmpty) {
            failed++;
          } else {
            setState(() => record.placeName = place);
            await _save();
            acquired++;
          }
        } on Object {
          failed++;
        }
        if (!mounted) return;
        setState(() => _placeNamesProcessed++);
      }
      final failureMessage = failed == 0
          ? ''
          : '。$failed件は取得できませんでした。通信状態を確認して再試行してください';
      _showMessage('字名を$acquired件取得しました$failureMessage');
    } finally {
      if (mounted) setState(() => _fetchingPlaceNames = false);
    }
  }

  Widget _buildEditTab() {
    final records = _displayRecords();
    final grouped = <String, List<BirdRecord>>{};
    for (final record in records) {
      grouped.putIfAbsent(record.species, () => []).add(record);
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: _segmentLabel('古い順')),
                  ButtonSegment(value: true, label: _segmentLabel('新しい順')),
                ],
                selected: {_newestFirst},
                style: _segmentedButtonStyle(),
                onSelectionChanged: (value) =>
                    setState(() => _newestFirst = value.first),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: _segmentLabel('時系列')),
                  ButtonSegment(value: true, label: _segmentLabel('種別')),
                ],
                selected: {_groupBySpecies},
                style: _segmentedButtonStyle(),
                onSelectionChanged: (value) =>
                    setState(() => _groupBySpecies = value.first),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (records.isEmpty && _speciesOnlyNames.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('記録はまだありません'),
            ),
          )
        else if (_groupBySpecies)
          for (final species in (grouped.keys.toList()..sort())) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Text(
                species,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final record in grouped[species]!) _recordTile(record),
          ]
        else
          for (final record in records) _recordTile(record),
        if (_speciesOnlyNames.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            speciesOnlyHeading,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          for (final record in _visibleRecords.where((r) => r.speciesOnly))
            _recordTile(record),
        ],
        const SizedBox(height: 16),
        const Text('字名取得時に座標を国土地理院へ送信します（日本国内・オンライン）。出典：国土地理院'),
        OutlinedButton.icon(
          onPressed: _fetchingPlaceNames ? null : _fetchMissingPlaceNames,
          icon: _fetchingPlaceNames
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.location_city_outlined),
          label: Text(
            _fetchingPlaceNames
                ? '字名を取得中 ($_placeNamesProcessed / $_placeNamesTotal)'
                : '未取得の字名を一括取得',
          ),
        ),
      ],
    );
  }

  ButtonStyle _segmentedButtonStyle() {
    return const ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(0, 40)),
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 2, vertical: 8),
      ),
      textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
    );
  }

  Widget _segmentLabel(String text) {
    return SizedBox(
      width: 48,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            text,
            maxLines: 1,
            softWrap: false,
            textScaler: TextScaler.noScaling,
          ),
        ),
      ),
    );
  }

  Widget _recordTile(BirdRecord record) {
    return Card(
      child: ListTile(
        title: Text(
          record.speciesOnly
              ? record.species
              : '${record.species}  ${record.count}',
        ),
        subtitle: record.speciesOnly ? null : Text(_recordSubtitle(record)),
        trailing: Wrap(
          spacing: 4,
          children: [
            IconButton(
              tooltip: '編集',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _editRecord(record),
            ),
            IconButton(
              tooltip: '削除',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmDeleteRecord(record),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _TextPanel(title: '種ごとの総計', text: _summaryText(), onCopy: _copyText),
        _TextPanel(
          title: '字名ごとの記録',
          text: _placeSummaryText(),
          onCopy: _copyText,
        ),
        _TextPanel(
          title: '記録ごと（位置情報あり）',
          text: _recordExportText(withLocation: true),
          onCopy: _copyText,
        ),
        _TextPanel(
          title: '記録ごと（位置情報なし）',
          text: _recordExportText(withLocation: false),
          onCopy: _copyText,
        ),
      ],
    );
  }

  Widget _buildSettingsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('位置情報', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        const Text('位置情報はブラウザのサイト設定で許可してください。鳥の記録は測位を待たずに保存します。'),
        const SizedBox(height: 16),
        Text('端末内の保存', style: Theme.of(context).textTheme.titleLarge),
        Text(_storageStatus),
        TextButton(
          onPressed: _checkStorage,
          child: const Text('保存状態を確認・永続保存を要求'),
        ),
        const Text('オフラインでも記録・編集・集計できます。地図と字名の取得には通信が必要です。'),
        const Text('ホーム画面への追加はブラウザのメニューから行えます。'),
        const SizedBox(height: 24),
        Text('よく見る鳥を設定', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _newBirdController,
                decoration: const InputDecoration(
                  hintText: '種名',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _addBirdButton(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _addBirdButton, child: const Text('追加')),
          ],
        ),
        const SizedBox(height: 16),
        for (final bird in _birdList)
          Card(
            child: ListTile(
              title: Text(bird),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _removeBirdButton(bird),
              ),
            ),
          ),
      ],
    );
  }
}

class _TripTimeField extends StatelessWidget {
  const _TripTimeField({
    required this.label,
    required this.hourController,
    required this.minuteController,
    required this.onPick,
  });

  final String label;
  final TextEditingController hourController;
  final TextEditingController minuteController;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final hour = hourController.text.isEmpty ? '--' : hourController.text;
    final minute = minuteController.text.isEmpty ? '--' : minuteController.text;

    return SizedBox(
      width: 112,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            child: Text(
              label == '開始' ? '始' : '終',
              style: Theme.of(context).textTheme.labelSmall,
              textScaler: TextScaler.noScaling,
            ),
          ),
          const SizedBox(width: 2),
          Text(
            '$hour:$minute',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
            textScaler: TextScaler.noScaling,
          ),
          Tooltip(
            message: '$label時刻を選択',
            child: InkResponse(
              radius: 16,
              onTap: onPick,
              child: const SizedBox(
                width: 24,
                height: 32,
                child: Icon(Icons.schedule, size: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimeWheelPicker extends StatelessWidget {
  const _TimeWheelPicker({
    required this.label,
    required this.itemCount,
    required this.controller,
    required this.onSelectedItemChanged,
  });

  final String label;
  final int itemCount;
  final FixedExtentScrollController controller;
  final ValueChanged<int> onSelectedItemChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Expanded(
          child: CupertinoPicker(
            scrollController: controller,
            itemExtent: 42,
            magnification: 1.18,
            useMagnifier: true,
            onSelectedItemChanged: onSelectedItemChanged,
            children: [
              for (var index = 0; index < itemCount; index++)
                Center(
                  child: Text(
                    index.toString().padLeft(2, '0'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SavePanel extends StatelessWidget {
  const _SavePanel({
    required this.speciesOnly,
    required this.countText,
    required this.onMinus,
    required this.onPlus,
    required this.onReset,
    required this.onSave,
    required this.saving,
  });

  final bool speciesOnly;
  final String countText;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final VoidCallback onReset;
  final VoidCallback? onSave;
  final bool saving;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            if (speciesOnly)
              const Text('種のみ', style: TextStyle(fontWeight: FontWeight.bold))
            else ...[
              IconButton(onPressed: onMinus, icon: const Icon(Icons.remove)),
              SizedBox(
                width: 62,
                child: Center(
                  child: Text(
                    countText,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              IconButton(onPressed: onPlus, icon: const Icon(Icons.add)),
            ],
            const Spacer(),
            IconButton(
              tooltip: 'リセット',
              onPressed: onReset,
              icon: const Icon(Icons.restart_alt),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: onSave,
              icon: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(saving ? '保存中' : '記録'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocationPanel extends StatelessWidget {
  const _LocationPanel({
    required this.status,
    required this.locationText,
    required this.updatedText,
    required this.refreshing,
    required this.onRefresh,
  });

  final String status;
  final String locationText;
  final String updatedText;
  final bool refreshing;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.my_location_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(status, style: Theme.of(context).textTheme.labelLarge),
                  Text(
                    locationText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    updatedText,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: refreshing ? null : onRefresh,
              icon: Icon(refreshing ? Icons.gps_not_fixed : Icons.refresh),
              label: const Text('更新'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TextPanel extends StatelessWidget {
  const _TextPanel({
    required this.title,
    required this.text,
    required this.onCopy,
  });

  final String title;
  final String text;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        initiallyExpanded: true,
        title: Text(title),
        trailing: IconButton(
          tooltip: 'コピー',
          icon: const Icon(Icons.copy_outlined),
          onPressed: () => onCopy(text),
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(16),
              child: SelectableText(text),
            ),
          ),
        ],
      ),
    );
  }
}

class _EditRecordDialog extends StatefulWidget {
  const _EditRecordDialog({required this.record});

  final BirdRecord record;

  @override
  State<_EditRecordDialog> createState() => _EditRecordDialogState();
}

class _EditRecordDialogState extends State<_EditRecordDialog> {
  late final TextEditingController _speciesController;
  late final TextEditingController _countController;
  late final TextEditingController _timeController;
  late final TextEditingController _commentController;
  double? _latitude;
  double? _longitude;
  double? _locationAccuracy;
  DateTime? _locationTime;
  String _placeName = '';

  @override
  void initState() {
    super.initState();
    _speciesController = TextEditingController(text: widget.record.species);
    _countController = TextEditingController(text: widget.record.count);
    _timeController = TextEditingController(
      text: widget.record.time == null
          ? ''
          : '${widget.record.time!.hour.toString().padLeft(2, '0')}:${widget.record.time!.minute.toString().padLeft(2, '0')}',
    );
    _commentController = TextEditingController(text: widget.record.comment);
    _latitude = widget.record.latitude;
    _longitude = widget.record.longitude;
    _locationAccuracy = widget.record.locationAccuracy;
    _locationTime = widget.record.locationTime;
    _placeName = widget.record.placeName;
  }

  @override
  void dispose() {
    _speciesController.dispose();
    _countController.dispose();
    _timeController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _editLocationOnFullScreen() async {
    final point = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (context) => _FullScreenLocationEditor(
          latitude: _latitude,
          longitude: _longitude,
        ),
      ),
    );
    if (point == null || !mounted) return;
    setState(() {
      _latitude = point.latitude;
      _longitude = point.longitude;
      _locationAccuracy = null;
      _locationTime = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('記録を編集'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _speciesController,
                decoration: const InputDecoration(labelText: '鳥の名前'),
              ),
              if (widget.record.speciesOnly) const Text(speciesOnlyHeading),
              if (!widget.record.speciesOnly) ...[
                TextField(
                  controller: _timeController,
                  keyboardType: TextInputType.datetime,
                  decoration: const InputDecoration(
                    labelText: '時間',
                    hintText: 'HH:MM',
                  ),
                ),
                TextField(
                  controller: _countController,
                  decoration: const InputDecoration(labelText: '数'),
                ),
                TextField(
                  controller: _commentController,
                  minLines: 2,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'コメント',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: widget.record.stationarySessionId == null
                      ? _editLocationOnFullScreen
                      : null,
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('位置情報を全画面で編集'),
                ),
                const SizedBox(height: 4),
                Text(
                  _latitude == null || _longitude == null
                      ? '位置情報は未設定です'
                      : '${_latitude!.toStringAsFixed(6)}, ${_longitude!.toStringAsFixed(6)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (_placeName.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('地名: $_placeName'),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () {
            final parts = _timeController.text.split(':');
            if (_speciesController.text.trim().isEmpty) return;
            final oldTime = widget.record.time ?? DateTime.now();
            final hour = int.tryParse(parts.first) ?? oldTime.hour;
            final minute = parts.length > 1
                ? int.tryParse(parts[1]) ?? oldTime.minute
                : oldTime.minute;
            Navigator.pop(
              context,
              BirdRecord(
                id: widget.record.id,
                tripId: widget.record.tripId,
                species: _speciesController.text.trim(),
                count: _countController.text.trim(),
                speciesOnly: widget.record.speciesOnly,
                stationarySessionId: widget.record.stationarySessionId,
                time: widget.record.speciesOnly
                    ? null
                    : DateTime(
                        oldTime.year,
                        oldTime.month,
                        oldTime.day,
                        hour.clamp(0, 23),
                        minute.clamp(0, 59),
                      ),
                latitude: _latitude,
                longitude: _longitude,
                locationAccuracy: _locationAccuracy,
                locationTime: _locationTime,
                comment: _commentController.text.trim(),
                placeName: _placeName,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

enum _EditMapLayer { standard, satellite }

class _LocationEditMap extends StatefulWidget {
  const _LocationEditMap({
    required this.latitude,
    required this.longitude,
    required this.onChanged,
    this.showCompass = false,
  });

  final double? latitude;
  final double? longitude;
  final ValueChanged<LatLng> onChanged;
  final bool showCompass;

  @override
  State<_LocationEditMap> createState() => _LocationEditMapState();
}

class _LocationEditMapState extends State<_LocationEditMap> {
  final _mapController = MapController();
  final _tileProvider = NetworkTileProvider();
  _EditMapLayer _layer = _EditMapLayer.standard;
  LatLng? _selectedPoint;

  static const _fallbackCenter = LatLng(36.2048, 138.2529);

  @override
  void initState() {
    super.initState();
    _selectedPoint = _initialPoint();
  }

  @override
  void didUpdateWidget(covariant _LocationEditMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.latitude == widget.latitude &&
        oldWidget.longitude == widget.longitude) {
      return;
    }
    _selectedPoint = _initialPoint();
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  LatLng? _initialPoint() {
    final latitude = widget.latitude;
    final longitude = widget.longitude;
    if (latitude == null || longitude == null) return null;
    return LatLng(latitude, longitude);
  }

  LatLng get _center => _selectedPoint ?? _fallbackCenter;

  String get _tileUrl {
    switch (_layer) {
      case _EditMapLayer.standard:
        return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
      case _EditMapLayer.satellite:
        return 'https://server.arcgisonline.com/ArcGIS/rest/services/'
            'World_Imagery/MapServer/tile/{z}/{y}/{x}';
    }
  }

  void _selectPoint(LatLng point) {
    setState(() => _selectedPoint = point);
    widget.onChanged(point);
  }

  @override
  Widget build(BuildContext context) {
    final selectedPoint = _selectedPoint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<_EditMapLayer>(
          segments: const [
            ButtonSegment(
              value: _EditMapLayer.standard,
              icon: Icon(Icons.map_outlined),
              label: Text('地図'),
            ),
            ButtonSegment(
              value: _EditMapLayer.satellite,
              icon: Icon(Icons.satellite_alt_outlined),
              label: Text('航空写真'),
            ),
          ],
          selected: {_layer},
          onSelectionChanged: (value) => setState(() => _layer = value.first),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _center,
                    initialZoom: selectedPoint == null ? 5 : 16,
                    minZoom: 3,
                    maxZoom: 19,
                    backgroundColor: const Color(0xFFDDDDDD),
                    onLongPress: (_, point) => _selectPoint(point),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: _tileUrl,
                      userAgentPackageName: 'birdlog_app',
                      tileProvider: _tileProvider,
                      maxNativeZoom: 19,
                      keepBuffer: 3,
                      panBuffer: 1,
                      evictErrorTileStrategy: EvictErrorTileStrategy.none,
                    ),
                    if (selectedPoint != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: selectedPoint,
                            width: 36,
                            height: 36,
                            child: const Icon(
                              Icons.location_on,
                              color: Color(0xFF137A63),
                              size: 36,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                if (widget.showCompass)
                  Positioned(
                    top: 12,
                    left: 12,
                    child: _CardinalDirectionMark(
                      key: Key('cardinal-direction'),
                      onPressed: () => _mapController.rotate(0),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          selectedPoint == null
              ? '地図を長押しして位置情報を設定'
              : '${selectedPoint.latitude.toStringAsFixed(6)}, '
                    '${selectedPoint.longitude.toStringAsFixed(6)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _FullScreenLocationEditor extends StatefulWidget {
  const _FullScreenLocationEditor({
    required this.latitude,
    required this.longitude,
  });

  final double? latitude;
  final double? longitude;

  @override
  State<_FullScreenLocationEditor> createState() =>
      _FullScreenLocationEditorState();
}

class _FullScreenLocationEditorState extends State<_FullScreenLocationEditor> {
  LatLng? _selectedPoint;

  @override
  void initState() {
    super.initState();
    final latitude = widget.latitude;
    final longitude = widget.longitude;
    if (latitude != null && longitude != null) {
      _selectedPoint = LatLng(latitude, longitude);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedPoint = _selectedPoint;
    return Scaffold(
      appBar: AppBar(
        title: const Text('位置情報を編集'),
        actions: [
          TextButton(
            onPressed: selectedPoint == null
                ? null
                : () => Navigator.pop(context, selectedPoint),
            child: const Text('完了'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: _LocationEditMap(
            latitude: selectedPoint?.latitude,
            longitude: selectedPoint?.longitude,
            showCompass: true,
            onChanged: (point) => setState(() => _selectedPoint = point),
          ),
        ),
      ),
    );
  }
}

class _CardinalDirectionMark extends StatelessWidget {
  const _CardinalDirectionMark({super.key, this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '北を上にする',
      button: onPressed != null,
      child: Material(
        color: Colors.white.withValues(alpha: 0.9),
        elevation: 3,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: const SizedBox(
            width: 58,
            height: 58,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  top: 3,
                  child: Text(
                    '北',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Positioned(right: 4, child: Text('東')),
                Positioned(bottom: 3, child: Text('南')),
                Positioned(left: 4, child: Text('西')),
                Icon(Icons.navigation, color: Color(0xFFC62828), size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 種ごとに割り当てる観察地点マーカーの色。現在地マーカーの青（[_MapTabState._locationColor]）
/// と紛らわしくならないよう、彩度の高い青は外してある。
const _speciesFlagColors = <Color>[
  Color(0xFFD32F2F), // red
  Color(0xFFF57C00), // orange
  Color(0xFFFBC02D), // amber
  Color(0xFF388E3C), // green
  Color(0xFF00897B), // teal
  Color(0xFF7B1FA2), // purple
  Color(0xFFC2185B), // pink
  Color(0xFF5D4037), // brown
  Color(0xFF455A64), // blue grey
  Color(0xFF827717), // olive
  Color(0xFFE64A19), // deep orange
  Color(0xFF6D4C41), // taupe
];

class _LegacyMapTab extends StatefulWidget {
  const _LegacyMapTab({
    required this.records,
    required this.currentLocation,
    required this.refreshingLocation,
    required this.onRefreshLocation,
    required this.onEditRecord,
  });

  /// 位置情報つきの、現在のトリップの記録。
  final List<BirdRecord> records;
  final Position? currentLocation;
  final bool refreshingLocation;
  final VoidCallback onRefreshLocation;
  final Future<void> Function(BirdRecord record) onEditRecord;

  @override
  State<_LegacyMapTab> createState() => _LegacyMapTabState();
}

class _LegacyMapTabState extends State<_LegacyMapTab> {
  /// 現在地マーカーの青。種のマーカー色とは重ならない色にしている。
  static const _locationColor = Color(0xFF1E88E5);

  final _mapController = MapController();
  // 破棄は TileLayer 側が行う。
  final _tileProvider = NetworkTileProvider(abortObsoleteRequests: false);
  final _tileResetController = StreamController<void>.broadcast();
  final LayerHitNotifier<BirdRecord> _observationHitNotifier = ValueNotifier(
    null,
  );
  final Set<String> _hiddenSpecies = {};
  Offset _legendOffset = const Offset(12, 12);
  bool _legendOpen = true;
  bool _tileLoadFailed = false;

  @override
  void dispose() {
    _tileResetController.close();
    _mapController.dispose();
    _observationHitNotifier.dispose();
    super.dispose();
  }

  void _reloadTiles() {
    setState(() => _tileLoadFailed = false);
    _tileResetController.add(null);
  }

  List<String> _speciesCache = const [];
  Map<String, Color> _colorCache = const {};

  void _rebuildSpeciesIndex() {
    final names = _speciesInEighthEditionOrder(
      widget.records.map((record) => record.species),
    );
    _speciesCache = names;
    _colorCache = {
      for (var i = 0; i < names.length; i++)
        names[i]: _speciesFlagColors[i % _speciesFlagColors.length],
    };
  }

  Color _colorFor(String species) =>
      _colorCache[species] ?? _speciesFlagColors.first;

  /// 観察数に応じて円をわずかに拡大する（1羽で 24、100 羽以上で約 40）。
  double _markerDiameter(int count) {
    final clamped = count.clamp(1, 200);
    final t = math.log(clamped) / math.log(200);
    return 24 + 16 * t;
  }

  Widget _speciesDot(String species, {required double diameter}) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        color: _colorFor(species),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 2)],
      ),
    );
  }

  LatLng _initialCenter(List<BirdRecord> shown) {
    if (shown.isNotEmpty) {
      return LatLng(shown.last.latitude!, shown.last.longitude!);
    }
    final location = widget.currentLocation;
    if (location != null) return LatLng(location.latitude, location.longitude);
    return const LatLng(36.2048, 138.2529);
  }

  @override
  Widget build(BuildContext context) {
    _rebuildSpeciesIndex();
    final located = widget.records;
    final shown = located
        .where((record) => !_hiddenSpecies.contains(record.species))
        .toList();
    final species = _speciesCache;
    final location = widget.currentLocation;

    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            // Stack のルート要素をすべて Positioned にしておく。IndexedStack から
            // 渡る緩い制約（minHeight: 0）のもとで FlutterMap は 0×0 に潰れてしまう
            // ため、Positioned.fill で画面いっぱいのタイトな制約を与える。
            Positioned.fill(
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: _initialCenter(shown),
                  initialZoom: shown.isEmpty && location == null ? 5 : 15,
                  minZoom: 3,
                  maxZoom: 19,
                  keepAlive: true,
                  backgroundColor: const Color(0xFFDDDDDD),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'birdlog_app',
                    // 標準の再試行付きプロバイダーを使う。古い要求は安全に
                    // 中断して、連続ズーム後の現在地のタイルを優先する。
                    tileProvider: _tileProvider,
                    reset: _tileResetController.stream,
                    errorTileCallback: (_, _, _) {
                      if (!mounted || _tileLoadFailed) return;
                      setState(() => _tileLoadFailed = true);
                    },
                    maxNativeZoom: 19,
                    // 直前のズーム階層を余裕をもって残し、新しいタイルが届く
                    // まで地図が空白にならないようにする。
                    keepBuffer: 6,
                    panBuffer: 2,
                    // 再読み込み時に失敗済みタイルを ImageCache から除外する。
                    evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
                    tileDisplay: const TileDisplay.fadeIn(
                      startOpacity: 1,
                      reloadStartOpacity: 1,
                    ),
                  ),
                  if (location != null)
                    CircleLayer(
                      circles: [
                        CircleMarker(
                          point: LatLng(location.latitude, location.longitude),
                          radius: math.max(location.accuracy, 1),
                          useRadiusInMeter: true,
                          color: _locationColor.withValues(alpha: 0.15),
                          borderColor: Colors.white,
                          borderStrokeWidth: 2,
                        ),
                      ],
                    ),
                  if (location != null)
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: LatLng(location.latitude, location.longitude),
                          width: 24,
                          height: 24,
                          child: Container(
                            decoration: BoxDecoration(
                              color: _locationColor,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 3),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x33000000),
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  GestureDetector(
                    key: const Key('observation-marker-layer'),
                    behavior: HitTestBehavior.translucent,
                    onTap: () {
                      final hit = _observationHitNotifier.value;
                      if (hit == null || hit.hitValues.isEmpty) return;
                      _showRecordDetail(hit.hitValues.first);
                    },
                    child: CircleLayer<BirdRecord>(
                      hitNotifier: _observationHitNotifier,
                      circles: [
                        for (final record in shown)
                          CircleMarker<BirdRecord>(
                            point: LatLng(record.latitude!, record.longitude!),
                            radius:
                                _markerDiameter(_numericCountOf(record.count)) /
                                2,
                            color: _colorFor(record.species),
                            borderColor: Colors.white,
                            borderStrokeWidth: 2,
                            hitValue: record,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (located.isEmpty)
              Positioned(
                left: 12,
                right: 12,
                top: 12,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Expanded(child: Text('位置情報つきの記録はまだありません')),
                        OutlinedButton.icon(
                          onPressed: widget.refreshingLocation
                              ? null
                              : widget.onRefreshLocation,
                          icon: const Icon(Icons.my_location_outlined),
                          label: const Text('現在地'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_tileLoadFailed)
              Positioned(
                left: 12,
                right: 12,
                top: located.isEmpty ? 92 : 12,
                child: Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Icon(Icons.cloud_off_outlined),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text('地図データを読み込めません。通信状態を確認してください。'),
                        ),
                        TextButton(
                          onPressed: _reloadTiles,
                          child: const Text('再読み込み'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (species.isNotEmpty && _legendOpen)
              _buildLegend(species, constraints),
            Positioned(
              right: 12,
              bottom: 12,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (species.isNotEmpty)
                    FloatingActionButton.small(
                      heroTag: 'mapLegend',
                      tooltip: _legendOpen ? '凡例を隠す' : '凡例を表示',
                      onPressed: () =>
                          setState(() => _legendOpen = !_legendOpen),
                      child: const Icon(Icons.legend_toggle),
                    ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'mapFilter',
                    tooltip: '表示する種',
                    onPressed: () => _showSpeciesFilter(species),
                    child: const Icon(Icons.tune),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'mapReload',
                    tooltip: '地図を再読み込み',
                    onPressed: _reloadTiles,
                    child: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLegend(List<String> species, BoxConstraints constraints) {
    const width = 190.0;
    final maxDx = math.max(0.0, constraints.maxWidth - width);
    final maxDy = math.max(0.0, constraints.maxHeight - 80);
    final offset = Offset(
      _legendOffset.dx.clamp(0.0, maxDx),
      _legendOffset.dy.clamp(0.0, maxDy),
    );
    return Positioned(
      left: offset.dx,
      top: offset.dy,
      child: SizedBox(
        width: width,
        child: Card(
          elevation: 4,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onPanUpdate: (details) {
                  setState(() {
                    _legendOffset = Offset(
                      (offset.dx + details.delta.dx).clamp(0.0, maxDx),
                      (offset.dy + details.delta.dy).clamp(0.0, maxDy),
                    );
                  });
                },
                child: Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                  child: Row(
                    children: [
                      const Icon(Icons.drag_indicator, size: 16),
                      const SizedBox(width: 4),
                      const Expanded(child: Text('凡例')),
                      InkResponse(
                        radius: 16,
                        onTap: () => setState(() => _legendOpen = false),
                        child: const Icon(Icons.close, size: 16),
                      ),
                    ],
                  ),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                    for (final name in species)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 3,
                        ),
                        child: Row(
                          children: [
                            Opacity(
                              opacity: _hiddenSpecies.contains(name) ? 0.45 : 1,
                              child: _speciesDot(name, diameter: 16),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: _hiddenSpecies.contains(name)
                                    ? TextStyle(
                                        color: Theme.of(context).disabledColor,
                                      )
                                    : null,
                              ),
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

  Future<void> _showSpeciesFilter(List<String> species) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '表示する種',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () {
                            setSheetState(() {
                              setState(_hiddenSpecies.clear);
                            });
                          },
                          child: const Text('全選択'),
                        ),
                        TextButton(
                          onPressed: () {
                            setSheetState(() {
                              setState(() => _hiddenSpecies.addAll(species));
                            });
                          },
                          child: const Text('全選択解除'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final name in species)
                          FilterChip(
                            avatar: _speciesDot(name, diameter: 18),
                            label: Text(name),
                            selected: !_hiddenSpecies.contains(name),
                            onSelected: (selected) {
                              setSheetState(() {
                                setState(() {
                                  if (selected) {
                                    _hiddenSpecies.remove(name);
                                  } else {
                                    _hiddenSpecies.add(name);
                                  }
                                });
                              });
                            },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showRecordDetail(BirdRecord record) async {
    final hasLocation = record.latitude != null && record.longitude != null;
    final detail = [
      '日付: ${_calendarText(record.time!)}',
      '時刻: ${_clockText(record.time!)}',
      '種名: ${record.species}',
      '数: ${record.count}',
      if (record.comment.isNotEmpty) 'コメント: ${record.comment}',
      if (record.placeName.isNotEmpty) '地名: ${record.placeName}',
    ].join('\n');
    final locationText = hasLocation
        ? [
            '緯度: ${record.latitude!.toStringAsFixed(6)}',
            '経度: ${record.longitude!.toStringAsFixed(6)}',
            if (record.locationAccuracy != null)
              '精度: ±${record.locationAccuracy!.toStringAsFixed(0)}m',
            if (record.locationTime != null)
              '測位時刻: ${_clockText(record.locationTime!)}',
            '',
            '${record.latitude!.toStringAsFixed(6)}, ${record.longitude!.toStringAsFixed(6)}',
          ].join('\n')
        : '位置情報なし';
    final coordinateText = hasLocation
        ? '${record.latitude!.toStringAsFixed(6)}, ${record.longitude!.toStringAsFixed(6)}'
        : null;

    final action = await showModalBottomSheet<_MapDetailAction>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return DefaultTabController(
          length: 3,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      _speciesDot(record.species, diameter: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          record.species,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  TabBar(
                    onTap: (index) {
                      if (index == 2) {
                        Navigator.of(context).pop(_MapDetailAction.edit);
                      }
                    },
                    tabs: [
                      const Tab(text: '詳細'),
                      const Tab(text: '位置情報'),
                      const Tab(text: '編集'),
                    ],
                  ),
                  SizedBox(
                    height: 190,
                    child: TabBarView(
                      children: [
                        _CopyablePane(text: detail),
                        _CopyablePane(
                          text: locationText,
                          copyText: coordinateText,
                        ),
                        const SizedBox.shrink(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (action == _MapDetailAction.edit) {
      await widget.onEditRecord(record);
    }
  }
}

enum _MapDetailAction { edit }

/// 観察地点を表示するためだけに作り直した、独立した地図タブ。
///
/// 記録・測位・位置情報編集の状態には触れず、受け取った座標を表示する。
class _MapTab extends StatefulWidget {
  const _MapTab({
    required this.speciesOnlyText,
    required this.stationarySessions,
    required this.records,
    required this.currentLocation,
    required this.refreshingLocation,
    required this.onRefreshLocation,
    required this.onEditRecord,
  });

  final String speciesOnlyText;
  final List<StationarySession> stationarySessions;
  final List<BirdRecord> records;
  final Position? currentLocation;
  final bool refreshingLocation;
  final VoidCallback? onRefreshLocation;
  final Future<void> Function(BirdRecord record) onEditRecord;

  @override
  State<_MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<_MapTab> {
  static const _currentLocationColor = Color(0xFF1E88E5);
  static const _fallbackCenter = LatLng(36.2048, 138.2529);

  final _mapController = MapController();
  final _tileProvider = NetworkTileProvider();
  final _tileResetController = StreamController<void>.broadcast();
  _EditMapLayer _layer = _EditMapLayer.standard;
  final Set<String> _hiddenSpecies = {};
  Offset _legendOffset = const Offset(12, 72);
  bool _legendOpen = true;
  bool _showCurrentLocation = true;
  bool _hasTileError = false;

  @override
  void dispose() {
    _mapController.dispose();
    _tileResetController.close();
    super.dispose();
  }

  List<String> get _species {
    return _speciesInEighthEditionOrder(
      widget.records.map((record) => record.species),
    );
  }

  Color _colorFor(String species) {
    final index = _species.indexOf(species);
    return _speciesFlagColors[index < 0
        ? 0
        : index % _speciesFlagColors.length];
  }

  LatLng get _initialCenter {
    if (widget.records.isNotEmpty) {
      final record = widget.records.last;
      return LatLng(record.latitude!, record.longitude!);
    }
    if (widget.stationarySessions.isNotEmpty) {
      final session = widget.stationarySessions.last;
      return LatLng(session.latitude, session.longitude);
    }
    final location = widget.currentLocation;
    if (location != null) return LatLng(location.latitude, location.longitude);
    return _fallbackCenter;
  }

  double _markerDiameter(BirdRecord record) {
    final count =
        int.tryParse(RegExp(r'\d+').firstMatch(record.count)?.group(0) ?? '') ??
        1;
    final t = math.log(count.clamp(1, 200)) / math.log(200);
    return 24 + 16 * t;
  }

  /// 同一地点（約 10cm 以内）の記録は、座標を変えずに画面上だけ格子状に
  /// 分散する。記録数に応じてマーカー自体の大きさが変わるため、48px 間隔を
  /// 取ってタップ可能な状態を保つ。
  List<_MapRecordMarker> _spreadOverlappingRecords(List<BirdRecord> records) {
    final groups = <String, List<BirdRecord>>{};
    for (final record in records) {
      final key =
          '${record.latitude!.toStringAsFixed(6)},'
          '${record.longitude!.toStringAsFixed(6)}';
      groups.putIfAbsent(key, () => []).add(record);
    }

    final markers = <_MapRecordMarker>[];
    for (final group in groups.values) {
      final columns = math.sqrt(group.length).ceil();
      final rows = (group.length / columns).ceil();
      for (var index = 0; index < group.length; index++) {
        final column = index % columns;
        final row = index ~/ columns;
        markers.add(
          _MapRecordMarker(
            record: group[index],
            offset: Offset(
              (column - (columns - 1) / 2) * 48,
              (row - (rows - 1) / 2) * 48,
            ),
          ),
        );
      }
    }
    return markers;
  }

  void _reload() {
    setState(() => _hasTileError = false);
    _tileResetController.add(null);
  }

  String get _tileUrl {
    switch (_layer) {
      case _EditMapLayer.standard:
        return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
      case _EditMapLayer.satellite:
        return 'https://server.arcgisonline.com/ArcGIS/rest/services/'
            'World_Imagery/MapServer/tile/{z}/{y}/{x}';
    }
  }

  Widget _speciesDot(String species, {double diameter = 16}) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        color: _colorFor(species),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 2)],
      ),
    );
  }

  Widget _buildLegend(BoxConstraints constraints, List<String> species) {
    const width = 190.0;
    final maxDx = math.max(0.0, constraints.maxWidth - width);
    final maxDy = math.max(0.0, constraints.maxHeight - 80);
    final offset = Offset(
      _legendOffset.dx.clamp(0.0, maxDx),
      _legendOffset.dy.clamp(0.0, maxDy),
    );
    return Positioned(
      left: offset.dx,
      top: offset.dy,
      child: SizedBox(
        width: width,
        child: Card(
          elevation: 4,
          child: GestureDetector(
            onPanUpdate: (details) {
              setState(() {
                _legendOffset = Offset(
                  (offset.dx + details.delta.dx).clamp(0.0, maxDx),
                  (offset.dy + details.delta.dy).clamp(0.0, maxDy),
                );
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.drag_indicator, size: 18),
                      const SizedBox(width: 4),
                      const Expanded(child: Text('凡例（種別）')),
                      InkResponse(
                        radius: 16,
                        onTap: () => setState(() => _legendOpen = false),
                        child: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (widget.stationarySessions.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Icon(
                            Icons.circle,
                            color: Colors.deepPurple,
                            size: 16,
                          ),
                          SizedBox(width: 8),
                          Text('定点観察'),
                        ],
                      ),
                    ),
                  for (final name in species)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Opacity(
                            opacity: _hiddenSpecies.contains(name) ? 0.4 : 1,
                            child: _speciesDot(name),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showSpeciesFilter(List<String> species) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '地図に表示する種',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _hiddenSpecies.clear();
                          _showCurrentLocation = true;
                        });
                        setSheetState(() {});
                      },
                      child: const Text('全選択'),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _hiddenSpecies.addAll(species);
                          _showCurrentLocation = false;
                        });
                        setSheetState(() {});
                      },
                      child: const Text('選択解除'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (widget.currentLocation != null)
                  FilterChip(
                    avatar: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: _currentLocationColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                    label: const Text('現在地'),
                    selected: _showCurrentLocation,
                    onSelected: (selected) {
                      setState(() => _showCurrentLocation = selected);
                      setSheetState(() {});
                    },
                  ),
                if (widget.currentLocation != null) const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final name in species)
                      FilterChip(
                        avatar: _speciesDot(name, diameter: 18),
                        label: Text(name),
                        selected: !_hiddenSpecies.contains(name),
                        onSelected: (selected) {
                          setState(() {
                            if (selected) {
                              _hiddenSpecies.remove(name);
                            } else {
                              _hiddenSpecies.add(name);
                            }
                          });
                          setSheetState(() {});
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showRecordActions(BirdRecord record) async {
    final location =
        '${record.latitude!.toStringAsFixed(6)}, '
        '${record.longitude!.toStringAsFixed(6)}';
    final action = await showModalBottomSheet<_MapDetailAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                record.species,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text('時刻: ${_clockText(record.time!)}'),
              Text('数: ${record.count}'),
              if (record.comment.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('コメント: ${record.comment}'),
              ],
              if (record.placeName.isNotEmpty) Text('地名: ${record.placeName}'),
              Text('位置: $location'),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () {
                  unawaited(Clipboard.setData(ClipboardData(text: location)));
                  ScaffoldMessenger.of(
                    this.context,
                  ).showSnackBar(const SnackBar(content: Text('コピーしました')));
                },
                icon: const Icon(Icons.copy_outlined),
                label: const Text('緯度・経度をコピー'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, _MapDetailAction.edit),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('記録を編集'),
              ),
            ],
          ),
        ),
      ),
    );
    if (action == _MapDetailAction.edit && mounted) {
      await widget.onEditRecord(record);
    }
  }

  void _showStationaryDetails(StationarySession session) {
    final records = widget.records
        .where((r) => r.stationarySessionId == session.id)
        .toList();
    final species = _speciesInEighthEditionOrder(records.map((r) => r.species));
    String clock(DateTime time) =>
        '${time.year}/${time.month}/${time.day} '
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
    final duration = (session.endedAt ?? DateTime.now()).difference(
      session.startedAt,
    );
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.55,
            child: ListView(
              children: [
                Text('定点観察', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                Text('開始：${clock(session.startedAt)}'),
                Text(
                  '終了：${session.endedAt == null ? "観察中" : clock(session.endedAt!)}',
                ),
                Text(
                  '時間：${duration.inHours}時間${duration.inMinutes.remainder(60)}分${duration.inSeconds.remainder(60)}秒',
                ),
                const Divider(),
                Text('記録された種（${species.length}種）'),
                if (species.isEmpty) const Text('まだ記録がありません'),
                for (final name in species)
                  ListTile(
                    title: Text(name),
                    subtitle: Text(
                      records
                          .where((r) => r.species == name)
                          .map(
                            (r) =>
                                '${r.time!.hour.toString().padLeft(2, '0')}:${r.time!.minute.toString().padLeft(2, '0')}  ${r.count}',
                          )
                          .join('、'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final records = widget.records;
    final species = _species;
    final shownRecords = records
        .where((record) => !_hiddenSpecies.contains(record.species))
        .toList();
    final shownMarkers = _spreadOverlappingRecords(
      shownRecords.where((r) => r.stationarySessionId == null).toList(),
    );
    final shownSpecies = species
        .where((name) => !_hiddenSpecies.contains(name))
        .toList();
    final location = widget.currentLocation;
    return LayoutBuilder(
      builder: (context, constraints) => ColoredBox(
        color: const Color(0xFFDDDDDD),
        child: Stack(
          fit: StackFit.expand,
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _initialCenter,
                initialZoom:
                    records.isEmpty &&
                        location == null &&
                        widget.stationarySessions.isEmpty
                    ? 5
                    : 15,
                minZoom: 3,
                maxZoom: 19,
                backgroundColor: const Color(0xFFDDDDDD),
              ),
              children: [
                TileLayer(
                  urlTemplate: _tileUrl,
                  userAgentPackageName: 'birdlog_app',
                  tileProvider: _tileProvider,
                  reset: _tileResetController.stream,
                  errorTileCallback: (_, _, _) {
                    if (!mounted || _hasTileError) return;
                    setState(() => _hasTileError = true);
                  },
                  maxNativeZoom: 19,
                  evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
                ),
                if (location != null && _showCurrentLocation)
                  CircleLayer(
                    circles: [
                      CircleMarker(
                        point: LatLng(location.latitude, location.longitude),
                        radius: math.max(location.accuracy, 1),
                        useRadiusInMeter: true,
                        color: _currentLocationColor.withValues(alpha: 0.15),
                        borderColor: Colors.white,
                        borderStrokeWidth: 2,
                      ),
                    ],
                  ),
                if (location != null && _showCurrentLocation)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: LatLng(location.latitude, location.longitude),
                        width: 24,
                        height: 24,
                        child: Container(
                          decoration: BoxDecoration(
                            color: _currentLocationColor,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                          ),
                        ),
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    for (final session in widget.stationarySessions)
                      Marker(
                        point: LatLng(session.latitude, session.longitude),
                        width: 40,
                        height: 40,
                        child: GestureDetector(
                          key: Key('map-stationary-${session.id}'),
                          onTap: () => _showStationaryDetails(session),
                          child: Semantics(
                            label: '定点観察',
                            button: true,
                            child: Center(
                              child: Container(
                                width: 26,
                                height: 26,
                                decoration: BoxDecoration(
                                  color: Colors.deepPurple,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    for (final displayed in shownMarkers)
                      Marker(
                        point: LatLng(
                          displayed.record.latitude!,
                          displayed.record.longitude!,
                        ),
                        width: 240,
                        height: 240,
                        child: Center(
                          child: Transform.translate(
                            offset: displayed.offset,
                            child: SizedBox(
                              width: _markerDiameter(displayed.record),
                              height: _markerDiameter(displayed.record),
                              child: GestureDetector(
                                key: Key('map-record-${displayed.record.id}'),
                                onTap: () =>
                                    _showRecordActions(displayed.record),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: _colorFor(displayed.record.species),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2,
                                    ),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Color(0x66000000),
                                        blurRadius: 2,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
            if (records.isEmpty && widget.stationarySessions.isEmpty)
              Positioned(
                top: 68,
                left: 12,
                right: 12,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Expanded(child: Text('位置情報つきの記録はまだありません')),
                        OutlinedButton.icon(
                          onPressed: widget.refreshingLocation
                              ? null
                              : widget.onRefreshLocation,
                          icon: const Icon(Icons.my_location_outlined),
                          label: const Text('現在地'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 12,
              left: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<_EditMapLayer>(
                    style: const ButtonStyle(
                      backgroundColor: WidgetStatePropertyAll(Colors.white),
                      foregroundColor: WidgetStatePropertyAll(Colors.black87),
                    ),
                    segments: const [
                      ButtonSegment(
                        value: _EditMapLayer.standard,
                        icon: Icon(Icons.map_outlined),
                        label: Text('地図'),
                      ),
                      ButtonSegment(
                        value: _EditMapLayer.satellite,
                        icon: Icon(Icons.satellite_alt_outlined),
                        label: Text('航空写真'),
                      ),
                    ],
                    selected: {_layer},
                    onSelectionChanged: (value) {
                      setState(() {
                        _layer = value.first;
                        _hasTileError = false;
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  _MapNorthResetButton(
                    onPressed: () => _mapController.rotate(0),
                  ),
                ],
              ),
            ),
            Positioned(
              right: 12,
              bottom: 12,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (species.isNotEmpty)
                    FloatingActionButton.small(
                      heroTag: 'mapLegend',
                      tooltip: _legendOpen ? '凡例を隠す' : '凡例を表示',
                      onPressed: () =>
                          setState(() => _legendOpen = !_legendOpen),
                      child: Icon(
                        _legendOpen
                            ? Icons.legend_toggle
                            : Icons.legend_toggle_outlined,
                      ),
                    ),
                  if (species.isNotEmpty) const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'mapFilter',
                    tooltip: '表示する種',
                    onPressed: () => _showSpeciesFilter(species),
                    child: const Icon(Icons.tune),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'mapReload',
                    tooltip: '地図を再読み込み',
                    onPressed: _reload,
                    child: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            if (widget.speciesOnlyText.isNotEmpty)
              Positioned(
                left: 12,
                right: 76,
                bottom: 68,
                child: Card(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 120),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: Text(widget.speciesOnlyText),
                    ),
                  ),
                ),
              ),
            if (_hasTileError)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: const Text('地図データを読み込めません。通信状態を確認して再読み込みしてください。'),
                  ),
                ),
              ),
            if (_legendOpen && shownSpecies.isNotEmpty)
              _buildLegend(constraints, shownSpecies),
          ],
        ),
      ),
    );
  }
}

class _MapRecordMarker {
  const _MapRecordMarker({required this.record, required this.offset});

  final BirdRecord record;
  final Offset offset;
}

/// 地図の回転を解除して北を上に戻す方位マーク。
class _MapNorthResetButton extends StatelessWidget {
  const _MapNorthResetButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '北を上にする',
      child: Material(
        color: Colors.white,
        elevation: 3,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: const SizedBox(
            width: 52,
            height: 52,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  top: 2,
                  child: Text('北', style: TextStyle(fontSize: 10)),
                ),
                Positioned(
                  right: 3,
                  child: Text('東', style: TextStyle(fontSize: 10)),
                ),
                Positioned(
                  bottom: 2,
                  child: Text('南', style: TextStyle(fontSize: 10)),
                ),
                Positioned(
                  left: 3,
                  child: Text('西', style: TextStyle(fontSize: 10)),
                ),
                Icon(Icons.navigation, color: Color(0xFFC62828), size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CopyablePane extends StatelessWidget {
  const _CopyablePane({required this.text, this.copyText});

  final String text;
  final String? copyText;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: SelectableText(text),
          ),
        ),
        if (copyText != null)
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: copyText!)));
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('コピーしました')));
              },
              icon: const Icon(Icons.copy_outlined),
              label: const Text('緯度・経度をコピー'),
            ),
          ),
      ],
    );
  }
}
