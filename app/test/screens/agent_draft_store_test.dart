import 'package:drover/src/screens/agent_draft_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('write() stores a draft that read() returns', () {
    final store = AgentDraftStore();
    store.write('%1', 'draft one');

    expect(store.read('%1'), 'draft one');
    expect(store.read('%2'), isNull);
  });

  test('write() with empty text drops the stored draft', () {
    final store = AgentDraftStore();
    store.write('%1', 'draft one');

    store.write('%1', '');

    expect(store.read('%1'), isNull);
  });

  test('clear() removes only the given key', () {
    final store = AgentDraftStore();
    store.write('%1', 'draft one');
    store.write('%2', 'draft two');

    store.clear('%1');

    expect(store.read('%1'), isNull);
    expect(store.read('%2'), 'draft two');
  });
}
