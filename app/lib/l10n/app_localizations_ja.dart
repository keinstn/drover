// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get hostSetupTitle => 'ホスト設定';

  @override
  String get hostSetupHostLabel => 'ホスト';

  @override
  String get hostSetupHostRequired => 'ホストは必須です';

  @override
  String get hostSetupPortLabel => 'ポート';

  @override
  String get hostSetupPortInvalid => 'ポートは 1〜65535 の数値で入力してください';

  @override
  String get hostSetupUserLabel => 'ユーザー';

  @override
  String get hostSetupUserRequired => 'ユーザーは必須です';

  @override
  String get hostSetupPrivateKeyLabel => '秘密鍵 (PEM)';

  @override
  String get hostSetupPrivateKeyRequired => '秘密鍵は必須です';

  @override
  String get hostSetupPrivateKeyInvalid =>
      '秘密鍵の形式ではないようです。BEGIN/END 行を含む PEM 全体を貼り付けてください。';

  @override
  String get hostSetupPassphraseLabel => 'パスフレーズ';

  @override
  String get hostSetupAdvanced => '詳細設定';

  @override
  String get hostSetupHerdrBinLabel => 'Herdr バイナリのパス';

  @override
  String get hostSetupTestConnection => '接続テスト';

  @override
  String get hostSetupSave => '保存';

  @override
  String get hostSetupResetButton => 'ホストをリセット';

  @override
  String get hostResetDialogTitle => 'ホストをリセットしますか？';

  @override
  String get hostResetDialogBody => '保存された接続情報（SSH 鍵を含む）を削除し、セットアップ画面に戻ります。';

  @override
  String get commonCancel => 'キャンセル';

  @override
  String get commonReset => 'リセット';

  @override
  String testConnectionOk(int count) {
    return 'OK — エージェント $count 件';
  }

  @override
  String get notificationRegistrationFailed =>
      '通知を有効にできませんでした。Drover を開き直して再試行してください。';

  @override
  String get notificationTargetUnavailable => 'この通知のエージェントは利用できなくなりました。';

  @override
  String get hostPairNotifications => '通知用のペアリングコードを作成';

  @override
  String get hostPairingCodeTitle => '通知 plugin をペアリング';

  @override
  String get hostPairingCodeIntro =>
      'Herdr host で、次のコマンドをコピーして実行してください。/path/to/drover は checkout のパスに置き換えます。setup が表示した prompt にペアリングコードを貼り付けてください。';

  @override
  String get hostPairingLinkCommandLabel => '1. plugin を link（初回のみ）';

  @override
  String get hostPairingSetupCommandLabel => '2. setup を実行';

  @override
  String get hostPairingCodeLabel => '3. ペアリングコード';

  @override
  String get hostPairingUrlLabel => '完了 URL';

  @override
  String get hostPairAutoDetectedTitle => '通知 plugin を検出しました';

  @override
  String get hostPairAutoDetectedBody =>
      'この host には drover.notify plugin がすでに link されています。プッシュ通知のペアリングを自動設定しますか？';

  @override
  String get hostPairAutoDetectedConfirm => '設定する';

  @override
  String get hostPairAutoPairedTitle => '通知のペアリング完了';

  @override
  String get hostPairAutoPairedBody =>
      'この host はブロック中エージェントのプッシュ通知にペアリングされました。';

  @override
  String get commonClose => '閉じる';

  @override
  String get commonCopy => 'コピー';

  @override
  String get errorHostKeyMismatch =>
      'ホストの SSH 鍵が初回接続時に信頼したものと一致しません。サーバーを作り直した・交換した覚えがなければ、通信が傍受されている可能性があります。続行しないでください。';

  @override
  String get errorSshAuth => 'ホストにサインインできませんでした。ユーザー名・秘密鍵・パスフレーズを確認してください。';

  @override
  String get errorHostConnection =>
      'ホストに接続できませんでした。オンラインであること、アドレスとポートが正しいことを確認してください。';

  @override
  String get errorGeneric => '問題が発生しました。';

  @override
  String get errorDetailsLabel => '詳細';

  @override
  String get commonRetry => '再試行';

  @override
  String get commonStop => '停止';

  @override
  String get commonLaunchAgent => 'エージェントを起動';

  @override
  String get agentStatusIdle => 'ひとやすみ';

  @override
  String get agentStatusWorking => '作業中';

  @override
  String get agentStatusBlocked => '返事待ち';

  @override
  String get agentStatusDone => 'できました';

  @override
  String get agentStatusUnknown => '不明';

  @override
  String get agentModeNormal => '通常';

  @override
  String get agentModeAcceptEdit => '編集を承認';

  @override
  String get agentModePlan => 'プラン';

  @override
  String get agentModeAuto => 'オート';

  @override
  String get agentModeBypass => 'バイパス';

  @override
  String get agentComposerHint => 'メッセージを送る…';

  @override
  String get agentCycleModeTooltip => 'エージェントモードを切り替え (shift+tab)';

  @override
  String get agentRemoveImage => '画像を削除';

  @override
  String get agentAttachImage => '添付を追加';

  @override
  String get agentAttachFromLibrary => '写真';

  @override
  String get agentAttachFromCamera => 'カメラ';

  @override
  String get agentStopAgent => 'エージェントを停止';

  @override
  String get agentStopDictation => '音声入力を停止';

  @override
  String get agentDictateMessage => '音声入力';

  @override
  String get agentSendEscape => 'Esc キーを送信';

  @override
  String get agentSendEnter => 'Enter キーを送信';

  @override
  String get agentNativeHistory => '会話履歴';

  @override
  String get agentLiveTerminal => 'ライブターミナル';

  @override
  String get agentThinking => '思考中…';

  @override
  String get agentHistoryBeginning => '保持されているターミナル履歴の先頭に到達しました';

  @override
  String get agentAskUserSend => '送信';

  @override
  String get agentAskUserClose => '閉じる';

  @override
  String get agentAskUserCustomHint => '自由入力…';

  @override
  String agentAskUserQuestionNumber(int current, int total) {
    return '質問 $current / $total';
  }

  @override
  String get agentAskUserDismissed => 'この質問は利用できなくなりました';

  @override
  String agentAskUserSubmitError(String error) {
    return '回答を送信できませんでした: $error';
  }

  @override
  String herdAgentBlocked(String name) {
    return '$name がブロックされました';
  }

  @override
  String get herdStopDialogTitle => 'エージェントを停止しますか？';

  @override
  String herdStopDialogBody(String name, String paneId) {
    return '$name ($paneId) を停止します。実行中の作業は中断されます。';
  }

  @override
  String get herdNoAgents => 'エージェントが見つかりません';

  @override
  String get herdRenameWorkspaceTitle => 'ワークスペース名を変更';

  @override
  String get herdRenameWorkspaceField => 'ワークスペース名';

  @override
  String get herdRenameAgentTitle => 'エージェント名を変更';

  @override
  String get herdRenameAgentField => 'エージェント名';

  @override
  String get herdGreetingIntro => 'おかえりなさい。';

  @override
  String herdGreetingWaitingCount(int count) {
    return '$count体';
  }

  @override
  String get herdGreetingWaitingSuffix => 'があなたの返事を待っています。';

  @override
  String get herdGreetingAllClear => 'みんな順調です。';

  @override
  String get herdElapsedNow => 'いま';

  @override
  String herdElapsedMinutes(int minutes) {
    return '$minutes分前';
  }

  @override
  String herdElapsedHours(int hours) {
    return '$hours時間前';
  }

  @override
  String get herdSnippetThinking => '考えごと中…';

  @override
  String get agentSwitcherHerdTab => '一覧';

  @override
  String get launchButton => '起動';

  @override
  String get launchNoAgents => 'ホストに起動可能なエージェントが見つかりません';

  @override
  String get launchWorkingDir => '作業ディレクトリ';

  @override
  String get launchWorkingDirRequired => '作業ディレクトリは必須です';

  @override
  String get launchAgentName => 'エージェント名';

  @override
  String get launchNewWorkspace => '新規ワークスペース';

  @override
  String get launchExistingWorkspace => '既存のワークスペース';

  @override
  String get launchWorkspaceName => 'ワークスペース名';

  @override
  String get launchWorkspaceNameRequired => 'ワークスペース名は必須です';

  @override
  String get launchUseNewWorkspace => '代わりに新規ワークスペースを使う';

  @override
  String get launchNoExistingWorkspaces => '既存のワークスペースがありません';

  @override
  String get launchSelectWorkspace => 'ワークスペースを選択';

  @override
  String launchUnnamedWorkspace(String id) {
    return '名前なしワークスペース ($id)';
  }

  @override
  String get launchBrowseDir => '参照';

  @override
  String get dirPickerTitle => 'ディレクトリを選択';

  @override
  String get dirPickerUse => 'このディレクトリを使う';

  @override
  String get dirPickerParent => '上の階層へ';

  @override
  String get dirPickerShowHidden => '隠しフォルダを表示';

  @override
  String get dirPickerEmpty => 'サブフォルダがありません';
}
