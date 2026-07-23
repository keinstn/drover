import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

const _deviceIdKey = 'notification_device_id';
const _apnsTokenRetryDelay = Duration(milliseconds: 250);
const _apnsTokenMaxAttempts = 10;

typedef NotificationDelay = Future<void> Function(Duration duration);

enum NotificationAuthorization { authorized, denied }

abstract interface class PushMessaging {
  Future<NotificationAuthorization> requestAuthorization();
  Future<String?> getApnsToken();
  Future<String?> getFcmToken();
  Stream<String> get onTokenRefresh;
}

abstract interface class DeviceRegistrationGateway {
  Future<void> registerDevice({
    required String deviceId,
    required String fcmToken,
    required String platform,
  });
}

abstract interface class DeviceIdStore {
  Future<String> readOrCreate();
}

class FirebasePushMessaging implements PushMessaging {
  FirebasePushMessaging([FirebaseMessaging? messaging])
    : _messaging = messaging ?? FirebaseMessaging.instance;

  final FirebaseMessaging _messaging;

  @override
  Future<NotificationAuthorization> requestAuthorization() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    return switch (settings.authorizationStatus) {
      AuthorizationStatus.authorized ||
      AuthorizationStatus.provisional => NotificationAuthorization.authorized,
      AuthorizationStatus.denied ||
      AuthorizationStatus.notDetermined => NotificationAuthorization.denied,
    };
  }

  @override
  Future<String?> getApnsToken() => _messaging.getAPNSToken();

  @override
  Future<String?> getFcmToken() => _messaging.getToken();

  @override
  Stream<String> get onTokenRefresh => _messaging.onTokenRefresh;
}

class FirebaseDeviceRegistrationGateway implements DeviceRegistrationGateway {
  FirebaseDeviceRegistrationGateway([FirebaseFunctions? functions])
    : _functions =
          functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

  final FirebaseFunctions _functions;

  @override
  Future<void> registerDevice({
    required String deviceId,
    required String fcmToken,
    required String platform,
  }) async {
    await _functions.httpsCallable('registerDevice').call<void>({
      'deviceId': deviceId,
      'fcmToken': fcmToken,
      'platform': platform,
    });
  }
}

class SecureStorageDeviceIdStore implements DeviceIdStore {
  SecureStorageDeviceIdStore({FlutterSecureStorage? storage, Uuid? uuid})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          ),
      _uuid = uuid ?? const Uuid();

  final FlutterSecureStorage _storage;
  final Uuid _uuid;

  @override
  Future<String> readOrCreate() async {
    final existing = await _storage.read(key: _deviceIdKey);
    if (existing != null) return existing;

    final deviceId = _uuid.v4();
    await _storage.write(key: _deviceIdKey, value: deviceId);
    return deviceId;
  }
}

/// Requests notification permission and registers this device with the
/// authenticated user's notification backend.
class NotificationRegistration {
  NotificationRegistration({
    PushMessaging? messaging,
    DeviceRegistrationGateway? gateway,
    DeviceIdStore? deviceIdStore,
    TargetPlatform? platform,
    NotificationDelay? delay,
  }) : _messaging = messaging ?? FirebasePushMessaging(),
       _gateway = gateway ?? FirebaseDeviceRegistrationGateway(),
       _deviceIdStore = deviceIdStore ?? SecureStorageDeviceIdStore(),
       _platform = platform ?? defaultTargetPlatform,
       _delay = delay ?? Future<void>.delayed;

  final PushMessaging _messaging;
  final DeviceRegistrationGateway _gateway;
  final DeviceIdStore _deviceIdStore;
  final TargetPlatform _platform;
  final NotificationDelay _delay;
  final _failures = StreamController<Object>.broadcast();
  StreamSubscription<String>? _tokenRefreshSubscription;
  Future<void>? _initialization;

  Stream<Object> get failures => _failures.stream;

  Future<void> initialize() {
    final initialization = _initialization;
    if (initialization != null) return initialization;
    return _initialize();
  }

  Future<void> _initialize() async {
    final future = _initializeOnce();
    _initialization = future;
    try {
      await future;
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  Future<void> _initializeOnce() async {
    if (await _messaging.requestAuthorization() ==
        NotificationAuthorization.denied) {
      return;
    }

    if (_requiresApnsToken) {
      await _requireApnsToken();
    }

    final fcmToken = await _messaging.getFcmToken();
    if (fcmToken == null) {
      throw StateError('FCM token is not available.');
    }

    await _registerToken(fcmToken);
    _tokenRefreshSubscription ??= _messaging.onTokenRefresh.listen(
      (token) => unawaited(_registerRefreshedToken(token)),
      onError: (Object error) => _failures.add(error),
    );
  }

  bool get _requiresApnsToken =>
      _platform == TargetPlatform.iOS || _platform == TargetPlatform.macOS;

  Future<void> _requireApnsToken() async {
    for (var attempt = 0; attempt < _apnsTokenMaxAttempts; attempt += 1) {
      if (await _messaging.getApnsToken() != null) return;
      if (attempt < _apnsTokenMaxAttempts - 1) {
        await _delay(_apnsTokenRetryDelay);
      }
    }
    throw StateError('APNs token is not available.');
  }

  String get _platformName => switch (_platform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.macOS => 'macos',
    _ => throw UnsupportedError('Notifications are unsupported on $_platform.'),
  };

  Future<void> _registerToken(String fcmToken) async {
    final deviceId = await _deviceIdStore.readOrCreate();
    await _gateway.registerDevice(
      deviceId: deviceId,
      fcmToken: fcmToken,
      platform: _platformName,
    );
  }

  Future<void> _registerRefreshedToken(String token) async {
    try {
      await _registerToken(token);
    } catch (error) {
      _failures.add(error);
    }
  }

  void dispose() {
    unawaited(_tokenRefreshSubscription?.cancel());
    unawaited(_failures.close());
  }
}
