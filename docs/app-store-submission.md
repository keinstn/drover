# App Store submission

Everything that goes into App Store Connect, kept here so it stays consistent
between versions and so the *reasoning* survives — App Store Connect has no
field for "why we answered it this way".

App Apple ID `6792428012` · bundle `com.keinstn.drover` · store name
**Drover for Herdr**.

> The App Review contact phone number is deliberately not recorded here. Enter
> it directly in App Store Connect.

## Subtitle (30 characters)

**en** — `Steer coding agents on the go`

**ja** — `自分のマシンのエージェントを操作`

## Keywords (100 characters, comma-separated)

Do not repeat words already in the app name — "Drover" and "Herdr" are indexed
from the title, so spending keyword characters on them is waste.

**en**

```
ssh,terminal,cli,developer,devtools,coding,agent,claude,codex,copilot,remote,tmux,prompt
```

**ja**

```
SSH,ターミナル,開発,エージェント,claude,codex,copilot,リモート,CLI,コーディング,端末,監視
```

## Description

### en

```
Drover turns the AI coding agents running on your own computer into something
you can supervise from your phone.

It is not a mobile terminal. Drover speaks the agent's language: it renders a
running session as a readable chat, turns permission prompts into buttons you
can tap, and tells you the moment an agent is waiting on you.

NO SERVER IN BETWEEN
Drover connects straight from your device to your own machine over SSH. There
is no service in the middle. Your transcripts, your commands and your code go
to your machine and nowhere else — the developer of this app cannot see them.

WHAT YOU CAN DO
• See every agent and its status at a glance — waiting for you, working, done
• Read the session as a chat, with Markdown, syntax-highlighted code and diffs
• Answer an agent's permission prompt by tapping a button instead of typing
  into a raw terminal pane
• Send follow-up instructions, cycle the agent's mode, or dictate by voice
• Attach a photo from your camera or library for the agent to look at
• Get a notification the moment an agent is blocked and needs you
• Switch between several machines, or watch them all in one list

TRY IT WITH NO SETUP
Tap "Try the demo" on the first screen. It runs a scripted session entirely on
your device, with no host and no connection, so you can see how Drover works
before setting anything up.

WHAT YOU NEED
Drover is a client for a machine you already own. To use it for real you need a
computer running Herdr (herdr.dev) with your coding agents in it, SSH access to
that machine with key-based authentication, and Herdr 0.7.5 or newer.

PRIVACY
Speech recognition runs entirely on your device — Drover will not fall back to
a server. Notifications carry a fixed message and never any of your transcript.
Your SSH key is stored in the iOS Keychain and never leaves your device.
```

### ja

```
Drover は、自分のコンピュータで動いている AI コーディングエージェントを、
スマートフォンから監督できるようにするアプリです。

モバイルターミナルではありません。Drover はエージェントの言葉を話します。
実行中のセッションを読めるチャットとして描画し、許可プロンプトをタップできる
ボタンに変え、エージェントがあなたを待っている瞬間に知らせます。

あいだにサーバーがありません
Drover は端末から自分のマシンへ SSH で直接つなぎます。途中に何のサービスも
ありません。トランスクリプトも、コマンドも、コードも、自分のマシンにだけ届き
ます。このアプリの開発者がそれらを見ることはできません。

できること
• すべてのエージェントと状態を一目で把握（返事待ち / 作業中 / できました）
• セッションをチャットとして読む。Markdown、シンタックスハイライト、diff 対応
• 許可プロンプトに、生のターミナルへ打ち込むのではなくボタンで答える
• 追加の指示を送る、モードを切り替える、音声で入力する
• カメラや写真ライブラリの画像を添付してエージェントに見せる
• エージェントが止まって助けを求めた瞬間に通知を受け取る
• 複数のマシンを切り替える、あるいはまとめて一覧で見る

セットアップなしで試せます
最初の画面の「デモを試す」をタップしてください。ホストにも接続にも依存せず、
端末の中だけで動くデモセッションが始まります。何かを用意する前に、Drover が
どう動くかを確かめられます。

必要なもの
Drover は、すでにあなたが持っているマシンのためのクライアントです。実際に使う
には、コーディングエージェントを動かしている Herdr (herdr.dev) 入りのコンピュータ、
鍵認証による SSH アクセス、そして Herdr 0.7.5 以降が必要です。

プライバシー
音声認識は完全に端末内で処理され、サーバーにフォールバックすることはありません。
通知には固定の文面のみが入り、トランスクリプトの内容は一切含まれません。SSH の
秘密鍵は iOS キーチェーンに保存され、端末の外に出ることはありません。
```

## Promotional text (170 characters, optional)

Updatable without a new build or review, so use it for anything time-sensitive.

**en** — `Supervise the coding agents on your own machine from your phone. Read the session as chat, answer permission prompts with a tap, and get told the moment one is blocked.`

**ja** — `自分のマシンで動くコーディングエージェントを、スマートフォンから監督。セッションをチャットとして読み、許可プロンプトはタップで答え、止まった瞬間に通知が届きます。`

## App Review Information

**Sign-in required: No.** Drover has no accounts. The demo makes the app fully
reviewable without a Herdr host, so no demo credentials are needed.

### Review notes

```
Drover is a client for a machine the reviewer does not need. To see the app
working with no setup at all, tap "Try the demo" on the first screen. It runs a
scripted agent session entirely on the device — no host, no network, no
account. From there you can open the agent, answer its permission prompt by
tapping "Yes", and send a follow-up message.

On the guideline about executing code: Drover does not download, generate or
run code on the device. It displays and steers a process that is already
running on a computer the user owns, over SSH, exactly as an SSH or terminal
client does. From the project's own documentation: "The app never installs or
updates executable code on the Herdr host." This is architecturally the same
model as established SSH clients on the App Store.

Encryption: the app bundles dartssh2, an open-source library implementing
standard IETF SSH algorithms, so it is declared as using non-exempt
encryption and the export compliance questions are answered per build.
```

## App Privacy questionnaire

The boundary that decides every answer: **data flowing over SSH to the user's
own machine is not developer collection.** Only what lands in the developer's
Firebase project counts — the anonymous auth uid, FCM tokens, `deviceId`,
`hostId`, pairing-code hashes, credential hashes, de-duplication records and
rate-limit counters.

| Data type | Collected | Notes |
|---|---|---|
| Contact info, Health, Financial, Location, Sensitive info, Contacts | **No** | No account exists; no name or email is ever requested |
| User content — photos, audio, other | **No** | Attached images go over SSH to the user's own machine. Speech recognition is on-device only |
| Browsing / search history | **No** | |
| Identifiers — Device ID | **Yes** | FCM push token and `deviceId`. Purpose: App Functionality. **Not** linked to identity. **Not** used for tracking |
| Identifiers — User ID | **Yes** (judgment call) | The anonymous auth uid. See below |
| Usage data | **No** | No analytics SDK |
| Diagnostics | **No** (judgment call) | See below |
| Purchases | **No** | Free, no IAP |

**Tracking: No.** No advertising identifier, no data-broker sharing, no
cross-app tracking. Drover needs no App Tracking Transparency prompt.

Product page result: *Data Used to Track You* — none. *Data Linked to You* —
none. *Data Not Linked to You* — Device ID and User ID.

### The two judgment calls

**Is the anonymous uid a "User ID"?** It identifies an installation, not a
person: created automatically, never tied to a name or email, not recoverable on
a new device. Arguments exist both ways. **Declare it.** It costs nothing on the
product page — it joins Device ID in the same "Not Linked to You" bucket —
whereas under-declaring is a compliance problem.

**Do the Cloud Functions logs count as "Diagnostics"?** There is no crash or
performance SDK in the app. The backend logs host, pane and event identifiers
plus delivery counts, which are server-side operational logs of API calls, not
diagnostics gathered from the device, and they contain no content. **Answer No**,
and make sure the privacy policy discloses the logging — it does.

## Other App Store Connect fields

- **Category** — Developer Tools. Secondary is optional; Utilities fits.
- **Content rights** — the app contains no third-party content: **No**.
- **Copyright** — `2026 Keisuke Nishitani`
- **Price** — Free.
- **Privacy policy URL** — `https://keinstn.github.io/drover/privacy`
- **Support URL** — `https://keinstn.github.io/drover/support`
- **Screenshots** — `site/public/screenshots/{en,ja}/`, four per locale. See
  below; the app is iPhone-only, so no iPad sizes are required.

### Uploading the screenshots

Media Manager splits iPhone screenshots by display size, and **the wrong
section rejects a correct file**. Dropping a 1320 × 2868 capture into the 6.5"
section fails with "screenshots must be 1242 × 2688px, 2688 × 1242px,
1284 × 2778px or 2778 × 1284px" — those are 6.5" sizes, and nothing is wrong
with the file.

Use **iPhone 6.9-inch Display**. It accepts 1320 × 2868 and states that it
covers **6.5", 6.7" and 6.9"**, so this one section is the whole iPhone
requirement — there is no second set to capture.

Two things that are easy to get wrong:

- **Upload per locale.** The language selector sits at the top right of Media
  Manager. Set it to English before uploading `en/`, switch it to Japanese
  before uploading `ja/`. Uploading without switching puts Japanese captures on
  the English listing.
- **Order matters.** Only the **first three** screenshots appear in the app
  install sheet. Upload in filename order — `01-hero-prompt` (the permission
  prompt as tappable buttons, the thing that distinguishes drover from a mobile
  terminal), `02-chat` (markdown, code and a diff), `03-herd` (several agents
  and their states), then `04-setup`, which is the one that does not make the
  install sheet.

### Age rating

Answer carefully so the app is **not** classified as offering unrestricted web
access. Drover is not a browser: it connects only to a machine the user
configures. It also does not host user-generated content — what it displays
comes from the user's own machine, not from other users, so no moderation
obligations apply.

## Standing conditions

These outlive the first submission. Breaking any of them breaks the submission.

1. **France stays excluded** from Pricing and Availability. The export
   compliance questionnaire is answered "not distributing in France", and the
   two must match. Adding France re-triggers the encryption documentation
   requirement, which needs a French encryption declaration approval
   certificate obtained from the French authority.
2. **Answer the export compliance questions on every build you distribute.**
   Standard algorithms not using or accessing the encryption within Apple's OS;
   no Category 5 Part 2 exemption; not distributing in France. Builds left
   unanswered in App Store Connect are harmless — only ones you ship need it.
3. **Never set `ITSAppUsesNonExemptEncryption` to `false`.** App Store Connect
   suggests it; it is generic copy for apps with no encryption. The key is
   deliberately absent from `Info.plist` — see the commit that removed it.
4. **`/privacy` and `/support` must not move.** They are registered in App Store
   Connect.
5. **No automatic TestFlight distribution.** The per-build compliance answer is
   a manual gate, so the Xcode Cloud distribution post-action was removed; it
   would sit pending forever and mask real build failures.
