import 'dart:convert';

import 'package:drover/src/infra/host_store.dart';
import 'package:drover/src/models/host_config.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

// In-memory FlutterSecureStorage backend; options-agnostic, so this only
// exercises the store's JSON/key contract, not real Keychain accessibility
// behaviour.
class _FakeSecureStoragePlatform extends FlutterSecureStoragePlatform {
  final data = <String, String>{};

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => data.containsKey(key);

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async => data.remove(key);

  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      data.clear();

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async => data[key];

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => data;

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async => data[key] = value;
}

HostConfig _config({
  String? name,
  String host = 'example.com',
  String? hostId,
}) {
  return HostConfig(
    name: name,
    host: host,
    user: 'me',
    privateKeyPem: '-----BEGIN OPENSSH PRIVATE KEY-----\n...',
    hostId: hostId,
  );
}

void main() {
  late _FakeSecureStoragePlatform platform;
  late HostStore store;

  setUp(() {
    platform = _FakeSecureStoragePlatform();
    FlutterSecureStoragePlatform.instance = platform;
    store = HostStore();
  });

  test('loadHosts() on empty storage returns empty state', () async {
    final state = await store.loadHosts();
    expect(state.hosts, isEmpty);
    expect(state.activeHostId, isNull);
  });

  test(
    'saveHosts()/loadHosts() roundtrip preserves hosts and active id',
    () async {
      await store.saveHosts(
        HostsState(
          hosts: [
            _config(name: 'Work box', host: 'a.example.com', hostId: 'id-a'),
            _config(host: 'b.example.com', hostId: 'id-b'),
          ],
          activeHostId: 'id-b',
        ),
      );

      final state = await store.loadHosts();
      expect(state.hosts, hasLength(2));
      expect(state.hosts[0].name, 'Work box');
      expect(state.hosts[0].host, 'a.example.com');
      expect(state.hosts[1].hostId, 'id-b');
      expect(state.activeHostId, 'id-b');
    },
  );

  test('loadHosts() migrates a legacy blob, minting a hostId', () async {
    platform.data['host_config'] = jsonEncode(_config().toJson());

    final state = await store.loadHosts();
    expect(state.hosts, hasLength(1));
    expect(state.hosts.single.host, 'example.com');
    expect(state.hosts.single.hostId, isNotNull);
    expect(state.activeHostId, state.hosts.single.hostId);
    expect(
      platform.data.containsKey('host_config'),
      isFalse,
      reason: 'migration must delete the legacy key',
    );
    expect(
      platform.data.containsKey('hosts_config'),
      isTrue,
      reason: 'migration must persist the new blob',
    );
  });

  test('loadHosts() migration preserves an existing hostId', () async {
    platform.data['host_config'] = jsonEncode(
      _config(hostId: 'legacy-id').toJson(),
    );

    final state = await store.loadHosts();
    expect(state.hosts.single.hostId, 'legacy-id');
    expect(state.activeHostId, 'legacy-id');
  });

  test('clear() removes both the new and the legacy key', () async {
    platform.data['host_config'] = jsonEncode(_config().toJson());
    await store.saveHosts(
      HostsState(
        hosts: [_config(hostId: 'id-a')],
        activeHostId: 'id-a',
      ),
    );

    await store.clear();
    expect(platform.data.containsKey('hosts_config'), isFalse);
    expect(platform.data.containsKey('host_config'), isFalse);
  });
}
