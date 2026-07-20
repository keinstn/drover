import 'package:drover/src/models/agent_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AgentStatus.fromName', () {
    test('maps known names', () {
      expect(AgentStatus.fromName('idle'), AgentStatus.idle);
      expect(AgentStatus.fromName('working'), AgentStatus.working);
      expect(AgentStatus.fromName('blocked'), AgentStatus.blocked);
      expect(AgentStatus.fromName('done'), AgentStatus.done);
    });

    test('falls back to unknown for null or unrecognized', () {
      expect(AgentStatus.fromName(null), AgentStatus.unknown);
      expect(AgentStatus.fromName('bogus'), AgentStatus.unknown);
    });
  });

  group('AgentInfo.fromJson', () {
    test('parses a real agent list item without a name', () {
      final json = {
        'agent': 'claude',
        'agent_status': 'idle',
        'cwd': '/Users/administrator/Projects/ideas',
        'focused': false,
        'foreground_cwd': '/Users/administrator/Projects/ideas',
        'pane_id': 'wB:p4',
        'revision': 0,
        'tab_id': 'wB:t1',
        'terminal_id': 'term_656c8fffa296b15',
        'workspace_id': 'wB',
      };

      final info = AgentInfo.fromJson(json);

      expect(info.agent, 'claude');
      expect(info.status, AgentStatus.idle);
      expect(info.cwd, '/Users/administrator/Projects/ideas');
      expect(info.foregroundCwd, '/Users/administrator/Projects/ideas');
      expect(info.paneId, 'wB:p4');
      expect(info.tabId, 'wB:t1');
      expect(info.workspaceId, 'wB');
      expect(info.focused, isFalse);
      expect(info.name, isNull);
    });

    test('parses name when present', () {
      final json = {
        'agent': 'claude',
        'agent_status': 'working',
        'cwd': '/tmp',
        'focused': true,
        'name': 'drover-spike-test',
        'pane_id': 'wB:p4',
        'tab_id': 'wB:t1',
        'workspace_id': 'wB',
      };

      final info = AgentInfo.fromJson(json);

      expect(info.name, 'drover-spike-test');
      expect(info.status, AgentStatus.working);
      expect(info.focused, isTrue);
      expect(info.foregroundCwd, isNull);
    });

    test('parses optional typed agent session metadata', () {
      final info = AgentInfo.fromJson({
        'agent': 'claude',
        'agent_status': 'idle',
        'cwd': '/tmp',
        'focused': false,
        'pane_id': 'wB:p4',
        'tab_id': 'wB:t1',
        'workspace_id': 'wB',
        'agent_session': {
          'source': 'claude',
          'agent': 'claude',
          'kind': 'id',
          'value': 'c7c50b87-4d4c-4a92-9396-2cfa4158612d',
        },
      });

      expect(info.agentSession?.source, 'claude');
      expect(info.agentSession?.agent, 'claude');
      expect(info.agentSession?.kind, 'id');
      expect(info.agentSession?.value, 'c7c50b87-4d4c-4a92-9396-2cfa4158612d');
    });

    test('ignores malformed optional agent session metadata', () {
      final info = AgentInfo.fromJson({
        'agent': 'claude',
        'agent_status': 'idle',
        'cwd': '/tmp',
        'focused': false,
        'pane_id': 'wB:p4',
        'tab_id': 'wB:t1',
        'workspace_id': 'wB',
        'agent_session': {'kind': 'id'},
      });

      expect(info.agentSession, isNull);
    });
  });
}
