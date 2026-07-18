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
  });

  factory AgentInfo.fromJson(Map<String, dynamic> json) {
    return AgentInfo(
      paneId: json['pane_id'] as String,
      workspaceId: json['workspace_id'] as String,
      tabId: json['tab_id'] as String,
      agent: json['agent'] as String,
      name: json['name'] as String?,
      status: AgentStatus.fromName(json['agent_status'] as String?),
      cwd: json['cwd'] as String,
      foregroundCwd: json['foreground_cwd'] as String?,
      focused: json['focused'] as bool? ?? false,
    );
  }

  final String paneId;
  final String workspaceId;
  final String tabId;
  final String agent;
  final String? name;
  final AgentStatus status;
  final String cwd;
  final String? foregroundCwd;
  final bool focused;
}
