---
titleTemplate: false
---

# Drover — サポート

Drover は、自分のコンピュータで動く AI コーディングエージェントを、スマートフォンから監督・操作するためのアプリです。

**連絡先:** kei.sj.nstn@gmail.com — 開発者にいちばん早く届く窓口です。https://github.com/keinstn/drover/issues に issue を作成していただいても構いません。

お問い合わせの際は、Drover のバージョン、iOS のバージョン、そして問題が起きたときにどんな操作をしていたかを添えてください。

## Drover を使うために必要なもの

Drover は、すでにお持ちのマシンに接続するためのクライアントです。単体では動作しません。次のものが必要です。

1. **[Herdr](https://herdr.dev) が動いているコンピュータ**と、その中で動かしているコーディングエージェント。
2. **そのマシンへ鍵認証で SSH 接続できること。**
   - macOS: システム設定 → 一般 → 共有 → リモートログイン (System Settings → General → Sharing → Remote Login)。
   - Windows: OpenSSH Server 機能をインストールします。**管理者**アカウントの場合、公開鍵は `~\.ssh\authorized_keys` ではなく `C:\ProgramData\ssh\administrators_authorized_keys` に置く必要があります。置き場所が違うと、接続は "All authentication methods failed" (すべての認証方式が失敗しました) で失敗します。
3. そのマシンに **Herdr 0.8.0 以降**。Drover はこれを必須条件としてチェックするため、これより古い Herdr ではエージェントを起動できません。Drover が利用している `agent prompt` と `--pane` / `--until` のコマンド形式は 0.7.5 以降にしか存在せず、さらに 0.8.0 からは、停止しているバックグラウンドサーバーを Herdr が明確に報告するようになったため、ネットワーク障害のように見えるエラーを表示する代わりに、Drover がその状態をそのままお伝えできます。

これらを用意する前にまず Drover の動きを見てみたい場合は、セットアップ画面のデモをお使いください。サンプルデータを使って、すべてデバイス内だけで動作します。

## よくあるトラブル

**"Connection closed before authentication" (認証の前に接続が閉じられました)**
ホスト側で、OS の SSH サーバーより先に別のものが SSH ポートに応答してしまい、OS が接続をまったく認識できていません。よくある原因は **Tailscale SSH** で、その接続チェックがセッションを横取りします。該当マシンで Tailscale SSH を無効にするか、マシン本来の SSH ポートに接続してください。VPN を使っていること自体は問題ではありません。Drover は VPN 経由でも問題なく動作しますので、VPN ではなく、ポートを横取りしているものを探してください。

**会話履歴が読みやすいチャットにならず、生のターミナル出力のまま表示される**
Drover は、そのエージェント向けの Herdr integration がインストールされている場合に、エージェント自身のセッション履歴を読み取ります。ホスト側で次のコマンドを実行してインストールしてください。

```sh
herdr integration install claude
herdr integration install codex
herdr integration install copilot
```

integration が効くのは、インストール**後**に開始したセッションだけです。実行したら、エージェントのセッションを新しく開始し直してください。integration がない場合、Drover はターミナルのペイン表示を読み取るフォールバックになり、読み取れる範囲は Herdr が保持しているスクロールバックの量に左右されます。

**音声入力が始まらない**
Drover はデバイス内で完結する音声認識しか使いません。お使いのデバイスがデバイス内で認識を実行できない場合、Drover はサーバー側の認識にフォールバックしないため、音声入力は利用できません。iOS の設定で、認識に使う言語がダウンロードされているか確認してください。

**通知が届かない**
通知にはホストとのペアリングが必要で、そのためには該当マシンに `drover.notify` Herdr plugin がインストールされている必要があります。通知の設定方法は https://github.com/keinstn/drover のドキュメントをご覧ください。通知が送られるのは `blocked` (返事待ち) のイベントだけで、エージェントが作業を終えたときには通知されません。

## プライバシー

Drover は、お使いのデバイスからご自身のマシンへ直接接続します。会話履歴やコマンド、コードが開発者に渡ることはありません。[プライバシーポリシー](/ja/privacy/)もあわせてご覧ください。

## ドキュメント

セットアップとコマンドの詳細: https://github.com/keinstn/drover
