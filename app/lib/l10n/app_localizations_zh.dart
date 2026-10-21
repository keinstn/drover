// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get hostSetupTitle => '主机设置';

  @override
  String get hostSetupNameLabel => '名称（可选）';

  @override
  String get hostSetupHostLabel => '主机';

  @override
  String get hostSetupHostRequired => '必须填写主机';

  @override
  String get hostSetupPortLabel => '端口';

  @override
  String get hostSetupPortInvalid => '端口必须是 1 到 65535 之间的数字';

  @override
  String get hostSetupUserLabel => '用户';

  @override
  String get hostSetupUserRequired => '必须填写用户';

  @override
  String get hostSetupPrivateKeyLabel => '私钥 PEM';

  @override
  String get hostSetupPrivateKeyRequired => '必须填写私钥';

  @override
  String get hostSetupPrivateKeyInvalid =>
      '这看起来不像私钥。请粘贴包含 BEGIN 和 END 行的完整 PEM 内容。';

  @override
  String get hostSetupPassphraseLabel => '密码短语';

  @override
  String get hostSetupAdvanced => '高级';

  @override
  String get hostSetupHerdrBinLabel => 'Herdr 二进制文件路径';

  @override
  String get hostSetupTestConnection => '测试连接';

  @override
  String get hostSetupSave => '保存';

  @override
  String get hostSetupDemoIntro => '刚开始使用 drover？先试试预设的演示会话——无需主机。';

  @override
  String get hostSetupDemoButton => '试用演示';

  @override
  String get demoHostDisplayName => '演示';

  @override
  String get demoBannerExit => '退出演示';

  @override
  String get demoBannerSetupConnection => '设置连接';

  @override
  String get demoBannerDoneCopy => '这只是演示。连接到你自己的主机后，就能进行真实操作。';

  @override
  String get hostListTitle => '主机';

  @override
  String get hostDeleteDialogTitle => '删除主机？';

  @override
  String hostDeleteDialogBody(String name) {
    return '将删除 $name 的已保存连接信息（包括 SSH 密钥）。';
  }

  @override
  String get hostSwitcherTitle => '切换主机';

  @override
  String get hostSwitcherManage => '管理主机';

  @override
  String get hostAllHosts => '所有主机';

  @override
  String get hostPickLaunchTarget => '在哪台主机上启动…';

  @override
  String get commonCancel => '取消';

  @override
  String get commonEdit => '编辑';

  @override
  String get commonDelete => '删除';

  @override
  String testConnectionOk(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个智能体',
      one: '1 个智能体',
    );
    return '成功 — $_temp0';
  }

  @override
  String get notificationRegistrationFailed => '无法启用通知。请重新打开 Drover 再试一次。';

  @override
  String get notificationTargetUnavailable => '此通知中的智能体已不可用。';

  @override
  String get hostPairNotifications => '创建通知配对码';

  @override
  String get hostPairingCodeTitle => '配对通知插件';

  @override
  String get hostPairingCodeIntro =>
      'Drover 未在此主机上找到通知插件。请在 Herdr 主机上运行以下命令安装插件，然后再次点按“创建通知配对码”——Drover 会找到它并完成配对。';

  @override
  String get hostPairingInstallCommandLabel => '安装插件';

  @override
  String get hostPairingManualNote => '想要手动配对？插件自己的设置脚本会要求输入下面的代码和 URL。';

  @override
  String get hostPairingCodeLabel => '配对码';

  @override
  String get hostPairingUrlLabel => '完成 URL';

  @override
  String get hostPairAutoDetectedTitle => '检测到通知插件';

  @override
  String get hostPairAutoDetectedBody =>
      'Drover 发现此主机已经关联了 drover.notify 插件。要自动设置推送通知配对吗？';

  @override
  String get hostPairAutoDetectedConfirm => '设置';

  @override
  String get hostPairAutoPairedTitle => '通知已配对';

  @override
  String get hostPairAutoPairedBody => '此主机现已配对，可在智能体需要回复时接收推送通知。';

  @override
  String get commonClose => '关闭';

  @override
  String get commonCopy => '复制';

  @override
  String get errorHostKeyMismatch =>
      '主机的 SSH 密钥与首次连接时信任的密钥不匹配。如果你没有重建或更换服务器，连接可能遭到拦截——请不要继续。';

  @override
  String get errorSshAuth => '无法登录主机。请检查用户名、私钥和密码短语。';

  @override
  String get errorHostConnection => '无法连接主机。请检查主机是否在线，以及地址和端口是否正确。';

  @override
  String get errorHostConnectionLost =>
      '与主机的连接已断开。如果你通过 VPN 连接，请确认 VPN 是否仍在连接。';

  @override
  String get errorHerdrServerUnreachable =>
      '已连接到主机，但 herdr 未在其上运行。请在主机上启动 herdr，然后重试。';

  @override
  String herdrVersionTooOld(String found, String minimum) {
    return '此主机上的 herdr $found 低于支持的最低版本 $minimum。请更新主机上的 herdr 才能启动智能体。';
  }

  @override
  String get errorGeneric => '出了点问题。';

  @override
  String get errorDetailsLabel => '详细信息';

  @override
  String get commonRetry => '重试';

  @override
  String get commonStop => '停止';

  @override
  String get commonLaunchAgent => '启动智能体';

  @override
  String get agentStatusIdle => '休息中';

  @override
  String get agentStatusWorking => '工作中';

  @override
  String get agentStatusBlocked => '等待你的回复';

  @override
  String get agentStatusDone => '已完成';

  @override
  String get agentStatusUnknown => '未知';

  @override
  String get agentModeNormal => '普通';

  @override
  String get agentModeAcceptEdit => '接受编辑';

  @override
  String get agentModePlan => '计划';

  @override
  String get agentModeAuto => '自动';

  @override
  String get agentModeBypass => '绕过';

  @override
  String get agentComposerHint => '发送消息…';

  @override
  String get agentCycleModeTooltip => '切换智能体模式（shift+tab）';

  @override
  String get agentRemoveImage => '移除图片';

  @override
  String get agentAttachImage => '添加附件';

  @override
  String get agentAttachFromLibrary => '照片';

  @override
  String get agentAttachFromCamera => '相机';

  @override
  String get agentStopAgent => '停止智能体';

  @override
  String get agentStopDictation => '停止听写';

  @override
  String get agentDictateMessage => '听写消息';

  @override
  String get agentSendEscape => '发送 Esc 键';

  @override
  String get agentSendEnter => '发送 Enter 键';

  @override
  String get agentShowArrowKeys => '显示按键';

  @override
  String get agentHideArrowKeys => '隐藏按键';

  @override
  String get agentSendArrowLeft => '发送左方向键';

  @override
  String get agentSendArrowUp => '发送上方向键';

  @override
  String get agentSendArrowDown => '发送下方向键';

  @override
  String get agentSendArrowRight => '发送右方向键';

  @override
  String get agentNativeHistory => '对话历史';

  @override
  String get agentLiveTerminal => '实时终端';

  @override
  String get agentThinking => '思考中…';

  @override
  String get agentHistoryBeginning => '已到达保留的终端历史记录开头';

  @override
  String get agentAskUserSend => '发送';

  @override
  String get agentAskUserClose => '关闭';

  @override
  String get agentAskUserCustomHint => '输入内容…';

  @override
  String agentAskUserQuestionNumber(int current, int total) {
    return '第 $current 个问题，共 $total 个';
  }

  @override
  String get agentAskUserDismissed => '此问题已不可用';

  @override
  String agentAskUserSubmitError(String error) {
    return '无法提交回答：$error';
  }

  @override
  String herdAgentBlocked(String name) {
    return '$name 在等你回复';
  }

  @override
  String get herdStopDialogTitle => '停止智能体？';

  @override
  String herdStopDialogBody(String name, String paneId) {
    return '将停止 $name（$paneId）。当前工作会被中断。';
  }

  @override
  String get herdNoAgents => '未找到智能体';

  @override
  String get herdRenameWorkspaceTitle => '重命名工作区';

  @override
  String get herdRenameWorkspaceField => '工作区名称';

  @override
  String get herdRenameAgentTitle => '重命名智能体';

  @override
  String get herdRenameAgentField => '智能体名称';

  @override
  String get herdGreetingIntro => '欢迎回来。';

  @override
  String herdGreetingWaitingCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个智能体',
      one: '1 个智能体',
    );
    return '$_temp0';
  }

  @override
  String get herdGreetingWaitingSuffix => '正在等待你的回复。';

  @override
  String get herdGreetingAllClear => '大家都在按计划进行。';

  @override
  String get herdElapsedNow => '刚刚';

  @override
  String herdElapsedMinutes(int minutes) {
    return '$minutes 分钟前';
  }

  @override
  String herdElapsedHours(int hours) {
    return '$hours 小时前';
  }

  @override
  String get herdSnippetThinking => '正在琢磨…';

  @override
  String get agentSwitcherHerdTab => '全部';

  @override
  String get launchButton => '启动';

  @override
  String get launchNoAgents => '主机上没有可启动的智能体';

  @override
  String get launchWorkingDir => '工作目录';

  @override
  String get launchWorkingDirRequired => '必须填写工作目录';

  @override
  String get launchAgentName => '智能体名称';

  @override
  String get launchNewWorkspace => '新建工作区';

  @override
  String get launchExistingWorkspace => '现有工作区';

  @override
  String get launchWorkspaceName => '工作区名称';

  @override
  String get launchWorkspaceNameRequired => '必须填写工作区名称';

  @override
  String get launchUseNewWorkspace => '改用新工作区';

  @override
  String get launchNoExistingWorkspaces => '没有现有工作区';

  @override
  String get launchSelectWorkspace => '选择工作区';

  @override
  String launchUnnamedWorkspace(String id) {
    return '未命名工作区（$id）';
  }

  @override
  String get launchBrowseDir => '浏览';

  @override
  String get dirPickerTitle => '选择目录';

  @override
  String get dirPickerUse => '使用此目录';

  @override
  String get dirPickerParent => '上级目录';

  @override
  String get dirPickerShowHidden => '显示隐藏文件夹';

  @override
  String get dirPickerEmpty => '没有子文件夹';

  @override
  String get settingsTitle => '设置';

  @override
  String get settingsAppearance => '外观';

  @override
  String get settingsTheme => '主题';

  @override
  String get settingsThemeSystem => '系统';

  @override
  String get settingsThemeLight => '浅色';

  @override
  String get settingsThemeDark => '深色';

  @override
  String get settingsLanguage => '语言';

  @override
  String get settingsLanguageSystem => '系统';

  @override
  String get settingsNotifications => '通知';

  @override
  String get settingsNotifyBlocked => '智能体需要回复时';

  @override
  String get settingsNotifyDone => '智能体完成时';

  @override
  String get settingsNotifyPluginUpdateTitle => '更新通知插件';

  @override
  String settingsNotifyPluginUpdateSubtitle(String host, String version) {
    return '$host 正在运行 $version';
  }

  @override
  String settingsNotifyPluginUpdateIntro(String host, String version) {
    return '$host 正在运行 drover-notify $version。请在 Herdr 主机上重新安装它，以获得最新通知。';
  }

  @override
  String get settingsNotifyPluginUninstallLabel => '1. 移除旧插件';

  @override
  String get settingsNotifyPluginInstallLabel => '2. 安装最新版';

  @override
  String get settingsDemo => '试用演示';

  @override
  String get settingsDemoSubtitle => '预设演示会话——无需主机';

  @override
  String get settingsVersion => '版本';

  @override
  String get settingsVersionCopied => '已复制版本';
}
