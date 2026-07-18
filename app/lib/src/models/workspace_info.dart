class WorkspaceInfo {
  const WorkspaceInfo({required this.workspaceId, required this.label});
  factory WorkspaceInfo.fromJson(Map<String, dynamic> json) => WorkspaceInfo(
    workspaceId: json['workspace_id'] as String,
    label: json['label'] as String? ?? '',
  );
  final String workspaceId;
  final String label;
}
