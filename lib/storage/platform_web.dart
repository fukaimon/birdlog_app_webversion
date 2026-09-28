import 'dart:convert';
import 'dart:js_interop';

@JS('birdlogStorage')
external JSPromise<JSString> _storage(JSString command, JSString payload);

Future<dynamic> call(String command, [Object? payload]) async => jsonDecode(
  (await _storage(command.toJS, jsonEncode(payload).toJS).toDart).toDart,
);

Future<String> storageStatus({bool requestPersistence = false}) async =>
    await call('status', {'request': requestPersistence}) as String;

Future<String> placeName(double latitude, double longitude) async =>
    await call('place', {'latitude': latitude, 'longitude': longitude})
        as String;
