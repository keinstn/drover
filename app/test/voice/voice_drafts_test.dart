import 'package:drover/src/voice/voice_drafts.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  final claude = fakeAgent(paneId: 'p1', title: 'Implement OAuth');
  final codex = fakeAgent(paneId: 'p2', kind: 'codex');

  test('add issues unique ids in order and keeps drafts pending', () {
    final drafts = VoiceDrafts();
    var notifications = 0;
    drafts.addListener(() => notifications++);

    final a = drafts.add(claude, 'add tests');
    final b = drafts.add(codex, 'review it');

    expect([a.id, b.id], ['d1', 'd2']);
    expect(drafts.pending, [a, b]);
    expect(drafts.byId('d2'), same(b));
    expect(drafts.byId('d9'), isNull);
    expect(drafts.isPending(a), isTrue);
    expect(notifications, 2);
    drafts.dispose();
  });

  test('markSent removes from pending but keeps byId; no-op twice', () {
    final drafts = VoiceDrafts();
    final a = drafts.add(claude, 'add tests');
    var notifications = 0;
    drafts.addListener(() => notifications++);

    drafts.markSent(a);
    drafts.markSent(a);

    expect(drafts.pending, isEmpty);
    expect(drafts.isPending(a), isFalse);
    expect(drafts.byId('d1'), same(a));
    expect(notifications, 1);
    drafts.dispose();
  });

  test('launch drafts share the id counter and the events', () async {
    final drafts = VoiceDrafts();
    final seen = <(VoiceDraftEventKind, String)>[];
    drafts.events.listen((e) => seen.add((e.kind, e.draft.id)));

    drafts.add(claude, 'x');
    final launch = drafts.addLaunch(
      kind: 'codex',
      cwd: '/tmp/proj',
      brief: 'add retries',
    );
    drafts.markSent(launch);
    await Future<void>.delayed(Duration.zero);

    expect(launch.id, 'd2');
    expect(drafts.byId('d2'), same(launch));
    expect(drafts.pending.single.id, 'd1');
    expect(seen, [
      (VoiceDraftEventKind.drafted, 'd1'),
      (VoiceDraftEventKind.drafted, 'd2'),
      (VoiceDraftEventKind.sent, 'd2'),
    ]);
    drafts.dispose();
  });

  test('events stream drafted then sent, in order', () async {
    final drafts = VoiceDrafts();
    final seen = <(VoiceDraftEventKind, String)>[];
    drafts.events.listen((e) => seen.add((e.kind, e.draft.id)));

    final a = drafts.add(claude, 'x');
    drafts.add(codex, 'y');
    drafts.markSent(a);
    await Future<void>.delayed(Duration.zero);

    expect(seen, [
      (VoiceDraftEventKind.drafted, 'd1'),
      (VoiceDraftEventKind.drafted, 'd2'),
      (VoiceDraftEventKind.sent, 'd1'),
    ]);
    drafts.dispose();
  });
}
