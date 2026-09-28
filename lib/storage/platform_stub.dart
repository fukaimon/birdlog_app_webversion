Future<dynamic> call(String command, [Object? payload]) =>
    throw UnsupportedError('This application uses browser storage.');

Future<String> storageStatus({bool requestPersistence = false}) async =>
    'ブラウザで確認してください。';

Future<String> placeName(double latitude, double longitude) async => '';
