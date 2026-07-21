enum AgentStatus {
  idle,
  working,
  blocked,
  done,
  unknown;

  static AgentStatus fromName(String? name) {
    if (name == null) return AgentStatus.unknown;
    return AgentStatus.values.firstWhere(
      (status) => status.name == name,
      orElse: () => AgentStatus.unknown,
    );
  }
}

/// Identifies the native session backing an agent, when herdr exposes one.
class AgentSession {
  const AgentSession({
    required this.source,
    required this.agent,
    required this.kind,
    required this.value,
  });

  factory AgentSession.fromJson(Map<String, dynamic> json) {
    final source = json['source'];
    final agent = json['agent'];
    final kind = json['kind'];
    final value = json['value'];
    if (source is! String ||
        agent is! String ||
        kind is! String ||
        value is! String) {
      throw const FormatException('invalid agent_session');
    }
    return AgentSession(source: source, agent: agent, kind: kind, value: value);
  }

  final String source;
  final String agent;
  final String kind;
  final String value;
}

class AgentInfo {
  const AgentInfo({
    required this.paneId,
    required this.workspaceId,
    required this.tabId,
    required this.agent,
    this.name,
    required this.status,
    required this.cwd,
    this.foregroundCwd,
    required this.focused,
    this.agentSession,
  });

  factory AgentInfo.fromJson(Map<String, dynamic> json) {
    final sessionJson = json['agent_session'];
    AgentSession? agentSession;
    if (sessionJson is Map<String, dynamic>) {
      try {
        agentSession = AgentSession.fromJson(sessionJson);
      } on FormatException {
        // Session metadata is optional. Retain a usable pane fallback when an
        // older or malformed herdr response does not provide its full shape.
      }
    }
    return AgentInfo(
      paneId: json['pane_id'] as String,
      workspaceId: json['workspace_id'] as String,
      tabId: json['tab_id'] as String,
      agent: json['agent'] as String?,
      name: json['name'] as String?,
      status: AgentStatus.fromName(json['agent_status'] as String?),
      cwd: json['cwd'] as String,
      foregroundCwd: json['foreground_cwd'] as String?,
      focused: json['focused'] as bool? ?? false,
      agentSession: agentSession,
    );
  }

  final String paneId;
  final String workspaceId;
  final String tabId;
  final String? agent;
  final String? name;
  final AgentStatus status;
  final String cwd;
  final String? foregroundCwd;
  final bool focused;
  final AgentSession? agentSession;
}
