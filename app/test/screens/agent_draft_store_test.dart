import 'package:drover/src/screens/agent_draft_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clearAll() drops every stored draft', () {
    final store = AgentDraftStore();
    store.write('%1', 'draft one');
    store.write('%2', 'draft two');

    store.clearAll();

    expect(store.read('%1'), isNull);
    expect(store.read('%2'), isNull);
  });
}
