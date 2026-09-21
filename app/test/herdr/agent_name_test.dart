import 'package:drover/src/herdr/agent_name.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// What herdr itself enforces (`invalid_agent_name`), verified on 0.9.1.
final _herdrName = RegExp(r'^[a-z][a-z0-9_-]{0,31}$');

void main() {
  group('agentNameSlug', () {
    test('folds uppercase and multibyte text into a legal slug', () {
      expect(agentNameSlug('My プロジェクト Repo'), 'my-repo');
      expect(agentNameSlug('My プロジェクト Repo'), matches(_herdrName));
    });

    test('truncates a base longer than 32 characters', () {
      final slug = agentNameSlug('a' * 40);
      expect(slug, 'a' * 32);
      expect(slug, matches(_herdrName));
    });

    test('does not leave a separator the truncation exposed', () {
      expect(agentNameSlug('${'a' * 31} b'), 'a' * 31);
    });

    test('drops leading characters before the first letter', () {
      expect(agentNameSlug('42-drover'), 'drover');
    });

    test('falls back when nothing survives', () {
      expect(agentNameSlug('日本語'), 'agent');
      expect(agentNameSlug(''), 'agent');
    });
  });

  group('startAgentWithFreeName', () {
    test('uses the plain slug when it is free', () async {
      final tried = <String>[];
      final name = await startAgentWithFreeName(
        base: 'Drover Repo',
        start: (name) async => tried.add(name),
      );
      expect(name, 'drover-repo');
      expect(tried, ['drover-repo']);
    });

    test('advances to -2 when the slug is taken', () async {
      final tried = <String>[];
      final name = await startAgentWithFreeName(
        base: 'drover',
        start: (name) async {
          tried.add(name);
          if (name == 'drover') {
            throw const HerdrException('agent_name_taken', 'taken');
          }
        },
      );
      expect(name, 'drover-2');
      expect(tried, ['drover', 'drover-2']);
    });

    test('keeps a suffixed name within 32 characters', () async {
      final tried = <String>[];
      final name = await startAgentWithFreeName(
        base: 'a' * 40,
        start: (name) async {
          tried.add(name);
          if (tried.length == 1) {
            throw const HerdrException('agent_name_taken', 'taken');
          }
        },
      );
      expect(name.length, 32);
      expect(name, '${'a' * 30}-2');
      expect(name, matches(_herdrName));
    });

    test('propagates any other HerdrException without retrying', () async {
      final tried = <String>[];
      await expectLater(
        startAgentWithFreeName(
          base: 'drover',
          start: (name) async {
            tried.add(name);
            throw const HerdrException('agent_pane_busy', 'busy');
          },
        ),
        throwsA(
          isA<HerdrException>().having(
            (e) => e.code,
            'code',
            'agent_pane_busy',
          ),
        ),
      );
      expect(tried, ['drover']);
    });

    test('gives up after attempt 99', () async {
      var calls = 0;
      await expectLater(
        startAgentWithFreeName(
          base: 'drover',
          start: (name) async {
            calls++;
            throw const HerdrException('agent_name_taken', 'taken');
          },
        ),
        throwsA(isA<HerdrException>()),
      );
      expect(calls, 99);
    });
  });
}
