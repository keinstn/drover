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
  String get hostSetupUserLabel => 'ユーザー';

  @override
  String get hostSetupUserRequired => 'ユーザーは必須です';

  @override
  String get hostSetupPrivateKeyLabel => '秘密鍵 (PEM)';

  @override
  String get hostSetupPrivateKeyRequired => '秘密鍵は必須です';

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
}
