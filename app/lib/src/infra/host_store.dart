import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/host_config.dart';

const _hostConfigKey = 'host_config';

/// Persists a single [HostConfig] blob in the platform secure storage.
class HostStore {
  HostStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<HostConfig?> load() async {
    final raw = await _storage.read(key: _hostConfigKey);
    if (raw == null) return null;
    return HostConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save(HostConfig config) async {
    await _storage.write(
      key: _hostConfigKey,
      value: jsonEncode(config.toJson()),
    );
  }

  Future<void> clear() async {
    await _storage.delete(key: _hostConfigKey);
  }
}
