import '../../l10n/app_localizations.dart';
import '../models/agent_info.dart';

/// User-facing localized label for an [AgentStatus].
String agentStatusLabel(AppLocalizations l10n, AgentStatus status) {
  switch (status) {
    case AgentStatus.idle:
      return l10n.agentStatusIdle;
    case AgentStatus.working:
      return l10n.agentStatusWorking;
    case AgentStatus.blocked:
      return l10n.agentStatusBlocked;
    case AgentStatus.done:
      return l10n.agentStatusDone;
    case AgentStatus.unknown:
      return l10n.agentStatusUnknown;
  }
}
