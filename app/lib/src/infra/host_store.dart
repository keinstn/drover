import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/host_config.dart';

const _hostConfigKey = 'host_config';

/// Persists a single [HostConfig] blob in the platform secure storage.
class HostStore {
  HostStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  // The SSH private key + passphrase live here. Pin them to this device (no
  // migration to a new device via encrypted backup) while still allowing
  // background access after first unlock (needed for notification-triggered
  // reconnects).
  static const _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );
  static const _macOptions = MacOsOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
    usesDataProtectionKeychain: false,
  );

  Future<HostConfig?> load() async {
    final raw = await _storage.read(
      key: _hostConfigKey,
      iOptions: _iosOptions,
      mOptions: _macOptions,
    );
    if (raw == null) return null;
    return HostConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save(HostConfig config) async {
    await _storage.write(
      key: _hostConfigKey,
      value: jsonEncode(config.toJson()),
      iOptions: _iosOptions,
      mOptions: _macOptions,
    );
  }

  Future<void> clear() async {
    await _storage.delete(
      key: _hostConfigKey,
      iOptions: _iosOptions,
      mOptions: _macOptions,
    );
  }
}
