import 'package:drover/src/infra/host_store.dart';
import 'package:drover/src/models/host_config.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

// Records call order/options instead of just storing values, so we can assert
// on the sequence save() issues. flutter_secure_storage's own
// TestFlutterSecureStoragePlatform is options-agnostic and can't distinguish
// "stale item written under old options" from "current options" the way the
// real Keychain does, so it can't reproduce errSecDuplicateItem itself -
// this only verifies the call contract our fix relies on.
class _RecordingSecureStoragePlatform extends FlutterSecureStoragePlatform {
  final calls = <String>[];
  final data = <String, String>{};

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async {
    calls.add('containsKey($key)');
    return data.containsKey(key);
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    calls.add('delete($key)');
    data.remove(key);
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    calls.add('deleteAll()');
    data.clear();
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    calls.add('read($key)');
    return data[key];
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async {
    calls.add('readAll()');
    return data;
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    calls.add('write($key)');
    data[key] = value;
  }
}

void main() {
  test('save() clears any pre-existing entry before writing', () async {
    final platform = _RecordingSecureStoragePlatform();
    FlutterSecureStoragePlatform.instance = platform;

    // Simulate a stale item left over from before the keychain options
    // changed (PR #98) - present under the key with no fix applied yet.
    platform.data['host_config'] = 'stale-legacy-value';

    final store = HostStore();
    await store.save(
      const HostConfig(
        host: 'example.com',
        port: 22,
        user: 'me',
        privateKeyPem: '-----BEGIN OPENSSH PRIVATE KEY-----\n...',
      ),
    );

    final deleteIndex = platform.calls.indexOf('delete(host_config)');
    final writeIndex = platform.calls.indexOf('write(host_config)');
    expect(
      deleteIndex,
      isNonNegative,
      reason: 'save() must clear a pre-existing entry before writing',
    );
    expect(
      writeIndex,
      greaterThan(deleteIndex),
      reason: 'delete() must run before write(), not after',
    );

    final loaded = await store.load();
    expect(loaded?.host, 'example.com');
  });
}
