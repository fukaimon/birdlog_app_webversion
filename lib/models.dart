class BirdTrip {
  BirdTrip({
    required this.id,
    required this.startedAt,
    this.title = '',
    this.startTime = '',
    this.endTime = '',
  });

  final String id;
  final DateTime startedAt;
  String title;
  String startTime;
  String endTime;

  Map<String, Object?> toJson() => {
    'id': id,
    'startedAt': startedAt.toIso8601String(),
    'title': title,
    'startTime': startTime,
    'endTime': endTime,
  };

  factory BirdTrip.fromJson(Map<String, dynamic> json) {
    return BirdTrip(
      id: json['id'] as String,
      startedAt:
          DateTime.tryParse(json['startedAt'] as String? ?? '') ??
          DateTime.now(),
      title: json['title'] as String? ?? '',
      startTime: json['startTime'] as String? ?? '',
      endTime: json['endTime'] as String? ?? '',
    );
  }
}

class StationarySession {
  StationarySession({
    required this.id,
    required this.tripId,
    required this.startedAt,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.locationTime,
    this.endedAt,
  });
  final String id;
  final String tripId;
  final DateTime startedAt;
  final double latitude;
  final double longitude;
  final double accuracy;
  final DateTime locationTime;
  DateTime? endedAt;

  Map<String, Object?> toRow() => {
    'id': id,
    'trip_id': tripId,
    'started_at': startedAt.toIso8601String(),
    'ended_at': endedAt?.toIso8601String(),
    'latitude': latitude,
    'longitude': longitude,
    'accuracy': accuracy,
    'location_time': locationTime.toIso8601String(),
  };
  factory StationarySession.fromRow(Map<String, Object?> row) =>
      StationarySession(
        id: row['id'] as String,
        tripId: row['trip_id'] as String,
        startedAt: DateTime.parse(row['started_at'] as String),
        endedAt: DateTime.tryParse(row['ended_at'] as String? ?? ''),
        latitude: (row['latitude'] as num).toDouble(),
        longitude: (row['longitude'] as num).toDouble(),
        accuracy: (row['accuracy'] as num).toDouble(),
        locationTime: DateTime.parse(row['location_time'] as String),
      );
}

const speciesOnlyHeading = '種のみ記録（位置情報・見た時間・数なし）';

class BirdRecord {
  BirdRecord({
    required this.id,
    required this.tripId,
    required this.species,
    required this.count,
    required this.time,
    this.latitude,
    this.longitude,
    this.locationAccuracy,
    this.locationTime,
    this.comment = '',
    this.placeName = '',
    this.stationarySessionId,
    this.speciesOnly = false,
  });

  final String id;
  final String tripId;
  String species;
  String count;
  DateTime? time;
  double? latitude;
  double? longitude;
  double? locationAccuracy;
  DateTime? locationTime;
  String comment;
  String placeName;
  String? stationarySessionId;
  final bool speciesOnly;

  Map<String, Object?> toJson() => {
    'id': id,
    'tripId': tripId,
    'species': species,
    'count': count,
    'time': time?.toIso8601String(),
    'latitude': latitude,
    'longitude': longitude,
    'locationAccuracy': locationAccuracy,
    'locationTime': locationTime?.toIso8601String(),
    'comment': comment,
    'placeName': placeName,
    'stationarySessionId': stationarySessionId,
    'speciesOnly': speciesOnly,
  };

  factory BirdRecord.fromJson(Map<String, dynamic> json) {
    return BirdRecord(
      id: json['id'] as String,
      tripId: json['tripId'] as String? ?? '',
      species: json['species'] as String? ?? '',
      count: json['count'] as String? ?? '0',
      speciesOnly: json['speciesOnly'] == true,
      time: json['speciesOnly'] == true
          ? null
          : DateTime.tryParse(json['time'] as String? ?? '') ?? DateTime.now(),
      latitude: _parseDouble(json['latitude']),
      longitude: _parseDouble(json['longitude']),
      locationAccuracy: _parseDouble(json['locationAccuracy']),
      locationTime: DateTime.tryParse(json['locationTime'] as String? ?? ''),
      comment: json['comment'] as String? ?? '',
      placeName: json['placeName'] as String? ?? '',
      stationarySessionId: json['stationarySessionId'] as String?,
    );
  }

  static double? _parseDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
