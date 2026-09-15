import 'package:drover/src/models/plugin_info.dart';
import 'package:drover/src/notifications/notify_plugin_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('flags a plugin older than the minimum', () {
    expect(isNotifyPluginStale('0.0.9'), isTrue);
    expect(isNotifyPluginStale('0.0.99'), isTrue);
    expect(isNotifyPluginStale('0.0'), isTrue);
    expect(isNotifyPluginStale('0.1.0'), isTrue);
    expect(isNotifyPluginStale('0.1.1'), isTrue);
  });

  test('accepts the minimum and anything newer', () {
    expect(isNotifyPluginStale(kMinNotifyPluginVersion), isFalse);
    expect(isNotifyPluginStale('0.2.1'), isFalse);
    expect(isNotifyPluginStale('0.3.0'), isFalse);
    expect(isNotifyPluginStale('1.0.0'), isFalse);
    expect(isNotifyPluginStale('0.10.0'), isFalse);
  });

  test('treats missing trailing segments as zero', () {
    expect(isNotifyPluginStale('0.2'), isFalse);
    expect(isNotifyPluginStale('0.2.0.0'), isFalse);
  });

  test('stays silent on a version it cannot parse', () {
    expect(isNotifyPluginStale(null), isFalse);
    expect(isNotifyPluginStale(''), isFalse);
    expect(isNotifyPluginStale('abc'), isFalse);
    expect(isNotifyPluginStale('0.0.9-beta'), isFalse);
    expect(isNotifyPluginStale('v0.0.9'), isFalse);
  });

  group('PluginInfo source kind', () {
    Map<String, dynamic> entry(Object? source) => {
      'plugin_id': 'drover.notify',
      'enabled': true,
      'plugin_root': '/checkout/drover-notify',
      'source': ?source,
    };

    test('reads the nested source.kind', () {
      expect(
        PluginInfo.fromJson(
          entry({
            'kind': 'github',
            'owner': 'keinstn',
            'repo': 'drover-notify',
          }),
        ).sourceKind,
        'github',
      );
      expect(PluginInfo.fromJson(entry({'kind': 'link'})).sourceKind, 'link');
    });

    test('is null when source is missing or malformed', () {
      expect(PluginInfo.fromJson(entry(null)).sourceKind, isNull);
      expect(PluginInfo.fromJson(entry('github')).sourceKind, isNull);
      expect(
        PluginInfo.fromJson(entry(<String, dynamic>{})).sourceKind,
        isNull,
      );
      expect(PluginInfo.fromJson(entry({'kind': 7})).sourceKind, isNull);
    });
  });
}
