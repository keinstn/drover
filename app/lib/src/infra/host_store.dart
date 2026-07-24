import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../models/host_config.dart';

const _hostsConfigKey = 'hosts_config';
const _legacyHostConfigKey = 'host_config';

/// The full multi-host state persisted by [HostStore]: every configured host
/// plus which one is currently active.
class HostsState {
  const HostsState({required this.hosts, this.activeHostId});

  final List<HostConfig> hosts;
  final String? activeHostId;
}

/// Persists the [HostsState] blob in the platform secure storage.
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

  Future<HostsState> loadHosts() async {
    final raw = await _storage.read(
      key: _hostsConfigKey,
      iOptions: _iosOptions,
      mOptions: _macOptions,
    );
    if (raw != null) {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return HostsState(
        hosts: [
          for (final host in json['hosts'] as List<dynamic>)
            HostConfig.fromJson(host as Map<String, dynamic>),
        ],
        activeHostId: json['activeHostId'] as String?,
      );
    }

    // Migrate a pre-multi-host single-config blob: mint a hostId when absent,
    // persist it under the new key, and drop the legacy entry.
    final legacy = await _storage.read(
      key: _legacyHostConfigKey,
      iOptions: _iosOptions,
      mOptions: _macOptions,
    );
    if (legacy == null) return const HostsState(hosts: []);
    var host = HostConfig.fromJson(jsonDecode(legacy) as Map<String, dynamic>);
    if (host.hostId == null) host = host.withHostId(const Uuid().v4());
    final state = HostsState(hosts: [host], activeHostId: host.hostId);
    await saveHosts(state);
    await _storage.delete(
      key: _legacyHostConfigKey,
      iOptions: _iosOptions,
      mOptions: _macOptions,
    );
    return state;
  }

  Future<void> saveHosts(HostsState state) async {
    // A plain write is fine here: the pre-#98 stale-entry collision
    // (errSecDuplicateItem) only applies to the legacy key, which we only
    // ever delete.
    await _storage.write(
      key: _hostsConfigKey,
      value: jsonEncode({
        'hosts': [for (final host in state.hosts) host.toJson()],
        'activeHostId': state.activeHostId,
      }),
      iOptions: _iosOptions,
      mOptions: _macOptions,
    );
  }

  Future<void> clear() async {
    await _storage.delete(
      key: _hostsConfigKey,
      iOptions: _iosOptions,
      mOptions: _macOptions,
    );
    await _storage.delete(
      key: _legacyHostConfigKey,
      iOptions: _iosOptions,
      mOptions: _macOptions,
    );
  }
}
