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

  @override
  String get settingsAssistant => '助手';

  @override
  String get settingsVoiceAssistant => '语音助手（实验性）';

  @override
  String get settingsVoiceAssistantSubtitle =>
      '与 drover 谈谈你的智能体。对话期间，智能体状态和回复的简短摘要会发送到 Google Gemini Live API。';

  @override
  String get settingsVoiceCredits => '语音额度';

  @override
  String get settingsVoiceCreditsSubtitle => '一次通话消耗一个额度，最长五分钟。';

  @override
  String get settingsVoiceCreditsCampaign =>
      '语音功能目前免费：使用 Apple 登录后会一次性获得少量免费通话额度。';

  @override
  String get settingsVoiceCreditsActivity => '最近的额度记录';

  @override
  String get settingsVoiceCreditsNone => '暂无记录。';

  @override
  String get settingsVoiceCreditsFailed => '无法加载你的余额。';

  @override
  String get voiceLedgerCall => '语音通话';

  @override
  String get voiceLedgerRefund => '退回';

  @override
  String get voiceLedgerGrant => '免费额度';

  @override
  String get settingsAccount => '账户';

  @override
  String get settingsAccountSignIn => '通过Apple登录';

  @override
  String get settingsAccountSignedIn => '已通过 Apple 登录';

  @override
  String get settingsAccountSignInFailed => '无法登录。点按以重试。';

  @override
  String get settingsAccountDelete => '删除账户';

  @override
  String get accountDeleteTitle => '删除账户？';

  @override
  String get accountDeleteBody =>
      '你的登录信息、主机配对和所有语音额度都将永久删除。额度无法退款或转移到其他账户。主机设置仍会保留在此设备上，但每台主机都需要重新配对才能接收通知。';

  @override
  String get accountDeleteConfirm => '删除';

  @override
  String get accountDeleteFailed => '无法删除账户。点按以重试。';

  @override
  String accountDeleteBalance(int credits) {
    String _temp0 = intl.Intl.pluralLogic(
      credits,
      locale: localeName,
      other: '$credits 次通话额度',
      one: '1 次通话额度',
    );
    return '其中包含 $_temp0。';
  }

  @override
  String get accountDeletedTitle => '账户已删除';

  @override
  String get accountDeletedNotifyBody => '通知配对也已随之移除。请重新配对每台主机，以继续接收通知。';

  @override
  String get accountDeletedManageHosts => '管理主机';

  @override
  String get herdVoiceButton => '语音助手（实验性）';

  @override
  String get herdVoiceButtonLive => '语音通话进行中';

  @override
  String get voiceStatusConnecting => '连接中…';

  @override
  String get voiceStatusReady => '就绪';

  @override
  String get voiceStatusLive => '正在聆听';

  @override
  String get voiceStatusSpeaking => '正在说话';

  @override
  String get voiceStatusEnded => '已结束';

  @override
  String voiceStatusError(String error) {
    return '错误：$error';
  }

  @override
  String get voiceMicPermissionDenied => '麦克风访问权限已关闭。请在设置中允许访问，才能与 drover 对话。';

  @override
  String get voiceNoCreditsTitle => '没有剩余额度';

  @override
  String get voiceNoCreditsBody =>
      '通话需要一个额度，但你已经没有额度了。免费额度只向已登录的账户发放一次。没有进行录音——麦克风从未打开，音频也没有离开手机。';

  @override
  String get voicePaidInterestPrompt =>
      '目前没有付费方案，也可能永远不会有。如果你愿意付费继续与智能体交流，告诉开发者你愿意付费，是让他知道这件事的唯一方式。';

  @override
  String get voicePaidInterestAction => '我愿意为此付费';

  @override
  String get voicePaidInterestDone =>
      '谢谢——已经记录下来了。这不是购买，也不是排队登记；语音功能是否会成为付费方案仍未决定。';

  @override
  String get voiceCampaignOverTitle => '免费额度已发完';

  @override
  String get voiceCampaignOverBody =>
      '语音功能在额度用完前免费，但所有人的额度都已经发完——这不是你的余额出了问题，你无需做任何处理。没有进行录音：麦克风从未打开。';

  @override
  String voiceCredits(int credits) {
    String _temp0 = intl.Intl.pluralLogic(
      credits,
      locale: localeName,
      other: '$credits 次通话额度',
      one: '1 次通话额度',
    );
    return '$_temp0';
  }

  @override
  String voiceCreditsGranted(int credits) {
    String _temp0 = intl.Intl.pluralLogic(
      credits,
      locale: localeName,
      other: '已获得 $credits 次免费通话额度',
      one: '已获得 1 次免费通话额度',
    );
    return '$_temp0';
  }

  @override
  String get voiceReceiptLength => '时长';

  @override
  String voiceReceiptLengthValue(int minutes, int seconds) {
    return '$minutes 分 $seconds 秒';
  }

  @override
  String get voiceReceiptCost => '费用';

  @override
  String get voiceReceiptBalance => '余额';

  @override
  String get voiceReceiptFootnote => '一次通话消耗一个额度——无论期间重新连接多少次。';

  @override
  String get voiceSignInTitle => '登录以获得免费通话额度';

  @override
  String get voiceSignInBody =>
      '语音助手目前免费，免费通话额度会发放给已登录的账户。使用 Apple 登录后会一次性获得少量免费通话额度，即使重新安装 drover 也能保留。drover 只向 Apple 请求稳定标识符：不请求姓名或电子邮件地址。';

  @override
  String voiceToolCalled(String name) {
    return '已调用 $name';
  }

  @override
  String get voiceInterrupted => '已中断';

  @override
  String get voiceGoingAway => '即将重新连接';

  @override
  String get voiceResumed => '已重新连接，继续进行';

  @override
  String get voiceEnded => '会话已结束';

  @override
  String get voiceEnd => '结束';

  @override
  String get voiceRestart => '重新开始';

  @override
  String get voiceStart => '开始';

  @override
  String get voiceGreeting => '我们从什么开始？';

  @override
  String get voiceClose => '关闭';

  @override
  String get voiceHint =>
      '“哪个智能体在等我？”\n“告诉 claude 也要添加测试”\n“发票 PDF 生成有问题——我该怎么提需求？”';

  @override
  String get voiceHintHandoff => '边聊边理清思路。确定后，通话会启动一个新智能体来处理。';

  @override
  String voiceEventFinished(String name) {
    return '$name 已完成';
  }

  @override
  String voiceEventBlocked(String name) {
    return '$name 正在等待你的回复';
  }

  @override
  String get voiceEventAnnounceFailed => '无法读取智能体状态';

  @override
  String voiceDraftPending(String agent) {
    return '等待发送给 $agent';
  }

  @override
  String voiceDraftSent(String agent) {
    return '已发送给 $agent';
  }

  @override
  String get voiceDraftSend => '发送';

  @override
  String get voiceUnsentDrafts => '仍有草稿等待发送——其卡片上的按钮仍然可用';

  @override
  String get voiceSendFailed => '无法发送消息';

  @override
  String voiceLaunchPending(String kind, String project) {
    return '等待在 $project 中启动 $kind';
  }

  @override
  String voiceLaunchHeader(String kind, String project) {
    return '$project 中的 $kind';
  }

  @override
  String voiceLaunchStarted(String kind, String project) {
    return '已在 $project 中启动 $kind';
  }

  @override
  String get voiceLaunchStart => '启动';

  @override
  String get voiceLaunchFailed => '无法启动智能体';

  @override
  String get voiceCapReached => '已达到会话时间限制';

  @override
  String get voiceBackgrounded => '应用已转入后台';

  @override
  String get voiceConsentTitle => '实验性功能：语音使用 Google Gemini';

  @override
  String get voiceConsentBody =>
      '语音助手运行于 Google Gemini Live。会话进行期间，你的麦克风音频以及对话双方的文字记录会发送给 Google，同时还会发送回答所需的上下文：智能体状态、会话标题和类型、项目文件夹名称、智能体正在等待的问题及其选项，以及智能体最近一次回复的纯文字部分——智能体完成工作时，即使你什么都没说，这条回复也会单独发送。回复中的代码（无论是代码块还是行内代码）都会被移除；操作失败时只会发送简短的错误码，而不是终端输出。这些文字会按原样发送，因此智能体在句子或问题的表述中写下的路径也会随之发送。会话未打开时不会发送任何内容。你使用 drover 的其他部分时，通话会继续保持聆听状态；离开应用会关闭麦克风并停止发送，回到对话时会自动重新打开麦克风并从离开处继续。会话达到时间限制后会自动结束，离开应用的时间也计入限制。只有“结束”会彻底结束通话，你可以随时点按它。';

  @override
  String get voiceConsentAccept => '允许并继续';

  @override
  String get voiceConsentDecline => '暂不允许';
}
