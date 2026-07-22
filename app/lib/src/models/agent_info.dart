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
    this.terminalTitle,
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
      terminalTitle: json['terminal_title_stripped'] as String?,
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

  /// The agent CLI's own terminal title (e.g. Claude/Copilot set a short
  /// summary of the current conversation via a terminal title escape), as
  /// captured and cleaned by herdr's `terminal_title_stripped`. drover never
  /// writes this — the CLI keeps it current, so it tracks the live
  /// conversation (and a resume/switch) instead of going stale.
  final String? terminalTitle;

  /// A human-readable session title for display: the agent's own
  /// [terminalTitle] with any CLI-specific suffix stripped, or null when the
  /// CLI has not set a usable title yet.
  String? get sessionTitle {
    final title = terminalTitle?.trim();
    if (title == null || title.isEmpty) return null;
    return stripAgentTitleSuffix(title);
  }
}

/// CLI-specific decorations appended to a terminal title that carry no
/// per-session meaning, so they are dropped from the displayed session title.
const _agentTitleSuffixes = <String>[' - GitHub Copilot'];

/// Removes a known trailing CLI decoration (see [_agentTitleSuffixes]) from a
/// terminal [title]. A no-op when none matches.
String stripAgentTitleSuffix(String title) {
  for (final suffix in _agentTitleSuffixes) {
    if (title.endsWith(suffix)) {
      return title.substring(0, title.length - suffix.length).trimRight();
    }
  }
  return title;
}
