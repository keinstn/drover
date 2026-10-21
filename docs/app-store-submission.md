# App Store submission

Everything that goes into App Store Connect, kept here so it stays consistent
between versions and so the *reasoning* survives — App Store Connect has no
field for "why we answered it this way".

App Apple ID `6792428012` · bundle `com.keinstn.drover`.

> The App Review contact phone number is deliberately not recorded here. Enter
> it directly in App Store Connect.

## Name and subtitle (30 characters each, both per-locale)

| | en | ja |
|---|---|---|
| **Name** | `Drover: Steer AI Coding Agents` (30) | `Drover: AIコーディングを見守る` (20) |
| **Subtitle** | `For Herdr. No relay, just SSH` (29) | `HerdrへSSHで直結。中継サーバーなし` (22) |

Both fields are per-locale — they are not translations of each other, and should
not be kept in sync.

### Why the name does not contain "Herdr"

Guideline **4.1(c)**, new as of 2025-11-13: *"You cannot use another developer's
icon, brand, or product name in your app's icon or name, without approval from
the developer."* Herdr is a third-party project
(`github.com/ogulcancelik/herdr`, Apache-2.0) that we do not own, so
`Drover for Herdr` — the name this app was reserved under — needs the
maintainer's written approval to be compliant.

It is deliberately **not** on the critical path. Approval would make
`Drover for Herdr` usable, and name and subtitle are metadata-only changes that
need no new build — so it stays available as an upgrade, not a blocker.

### Why the subtitle does contain it

Guideline **2.3.7** says subtitles "should not … reference other apps", so this
is a known, deliberate exposure rather than an oversight. Three things make it
the right trade:

- The failure mode is cheap. A flagged subtitle is a text edit; a flagged
  *name* would break the store identity, the site and the docs together.
- It is widely done — 7 of 14 surveyed apps in this exact category put a
  third-party product name in the subtitle.
- Qualifying the audience matters more than reach here. Someone who does not
  run Herdr cannot use this app, and the subtitle says so in four words.

The description carries a disclaimer, which addresses the *affiliation* concern
(5.2.1) — note that it does **not** cure 2.3.7, which forbids the reference
itself rather than the implication.

### Word choice

"No relay" rather than "no server": the app still needs a machine of your own to
connect to. "No server" reads as "nothing to set up", which is wrong. The ja
`中継サーバーなし` carries the same distinction.

## Keywords (100 characters, comma-separated)

Do not repeat words the name already carries. The name now indexes *coding*,
*agents* and *AI*, and the subtitle indexes *Herdr* and *SSH* — so none of those
belong here.

**en**

```
terminal,cli,developer,devtools,claude,codex,copilot,remote,tmux,prompt,mobile,pair
```

**ja**

```
ターミナル,開発,claude,codex,copilot,リモート,CLI,端末,監視,通知,スマホ,遠隔
```

`claude,codex,copilot` are third-party marks. Genuine-compatibility use is
common and these are the terms Japanese developers actually search for, but note
the exposure is larger than "Herdr" ever was, because those rights-holders
enforce.

## Description

### en

```
Drover is a mobile client for the AI coding agents you run under Herdr on your
own computer. It turns them into something you can supervise from your phone.

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
that machine with key-based authentication, and Herdr 0.8.0 or newer.

PRIVACY
Speech recognition runs entirely on your device — Drover will not fall back to
a server. Notifications carry a fixed message and never any of your transcript.
Your SSH key is stored in the iOS Keychain and never leaves your device.

Drover is an independent project. It is not affiliated with, endorsed by, or
sponsored by the Herdr project, Anthropic, OpenAI, or GitHub, and is not
certified by any of them.
```

### ja

```
Drover は、自分のコンピュータの Herdr で動かしている AI コーディング
エージェントを、スマートフォンから監督するためのクライアントです。

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
鍵認証による SSH アクセス、そして Herdr 0.8.0 以降が必要です。

プライバシー
音声認識は完全に端末内で処理され、サーバーにフォールバックすることはありません。
通知には固定の文面のみが入り、トランスクリプトの内容は一切含まれません。SSH の
秘密鍵は iOS キーチェーンに保存され、端末の外に出ることはありません。

Drover は独立したプロジェクトです。Herdr プロジェクト、Anthropic、OpenAI、
GitHub のいずれとも関係がなく、公認・推薦・認定を受けたものではありません。
```

## Promotional text (170 characters, optional)

Updatable without a new build or review, so use it for anything time-sensitive.
It sits **above** the description and is visible without tapping "more" — which
makes it, along with the description's first line, the place to put Herdr where
no guideline restricts it.

**en** — `A Herdr companion for your phone. Supervise the AI coding agents on your own machine: read the session as chat, answer prompts with a tap, know when one is blocked.`

**ja** — `Herdr のためのモバイルクライアント。自分のマシンで動く AI コーディングエージェントを監督し、セッションはチャットとして読み、許可プロンプトはタップで答え、止まった瞬間に通知が届きます。`

## App Review Information

**Sign-in required for review: No.** Drover creates a Firebase anonymous
account automatically at startup; there is no user-facing sign-in. The demo
makes the core UI reviewable without a Herdr host or credentials.

### Review notes

```
Drover is a client for a machine the reviewer does not need. To see the app
working without a Herdr host, tap "Try the demo" on the first screen. Its
scripted agent session runs entirely on the device and needs no host or demo
credentials. The app still initializes Firebase Anonymous Authentication and
App Check at startup. From the demo you can open the agent, answer its
permission prompt by tapping "Yes", and send a follow-up message.

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

This section is a **conservative recommendation, not an automatic update**.
App Store Connect values are manual: before submitting, open App Store Connect
→ the app → App Privacy, enter or amend every answer there, and recheck the
current Apple definitions and the privacy disclosures for the exact Firebase
SDK versions in the submitted build. Nothing in this repository can
change those values.

The boundary for the recommendation is broader than the developer's database.
Data sent from the app to a third-party processor can count as collection even
when the developer cannot view or retain the payload. SSH traffic sent only to
the user's own machine remains outside that boundary. Included are Firebase
account and notification identifiers, backend records and logs, and current
SDK privacy-manifest declarations.

| Data type | Recommended answer | Purpose / linkage rationale |
|---|---|---|
| Contact info | **No** | No name or email is ever requested |
| Health, Financial, Location, Sensitive info, Contacts | **No** | The shipped app does not request or transmit these categories |
| User content — photos, audio, other | **No** | Attached images go over SSH only to the user's own machine. Speech recognition is on-device only |
| Browsing / search history | **No** | None collected |
| Identifiers — Device ID | **Yes** | FCM token, app `deviceId`, and App Check/app-attestation signals. Purpose: App Functionality. Conservatively mark **Linked to User** because device records are stored below the Firebase uid, even though Firebase Messaging's manifest marks its Device ID unlinked. Not used for tracking |
| Identifiers — User ID | **Yes** | Firebase Auth creates a uid at startup and its privacy manifest declares User ID linked for App Functionality. Mark **Linked to User**. Not used for tracking |
| Usage data — Product Interaction | **Yes** (conservative) | Firebase Messaging declares unlinked Other Data for Analytics. Purpose: Analytics; mark **Not Linked to User**. Recheck whether ASC maps the SDK's current `Other Data Types` declaration here or under Other Data |
| Diagnostics — Other Diagnostic Data | **Yes** (conservative) | Firebase Auth and Firebase Messaging privacy manifests declare unlinked Other Diagnostic Data (Analytics and/or App Functionality), and App Check performs device/app attestation. Mark **Not Linked to User**. Backend operational logs reinforce choosing disclosure over a categorical No |
| Other Data | **Yes** (conservative) | Firebase Messaging's privacy manifest declares unlinked Other Data Types for Analytics. Mark **Not Linked to User** if ASC exposes this category separately from Usage Data |
| Purchases | **No** | Free, no IAP |

**Tracking: No.** There is no advertising identifier, data-broker sharing, or
cross-company use for targeted advertising or measurement, so no App Tracking
Transparency prompt is needed on the shipped behavior.

Expected conservative product-page result: *Data Used to Track You* — none.
*Data Linked to You* — User ID and Device ID.
*Data Not Linked to You* — Product Interaction/Other Usage Data, Other
Diagnostic Data, and Other Data, subject to the category names App Store
Connect currently presents.

### Why these answers are intentionally conservative

**User ID is linked.** Anonymous Auth creates the uid at app startup. It
identifies an installation rather than a person, but the Firebase Auth manifest
itself marks User ID as linked, so "Not Linked" is not a defensible blanket
answer.

**No Firebase Analytics or Crashlytics does not make Usage Data and Diagnostics
automatically No.** The bundled Firebase Auth and Messaging privacy manifests
make their own collected-data declarations, App Check sends attestation data,
and Cloud Functions writes
operational delivery logs. The conservative recommendation declares the
closest ASC categories as unlinked. Inspect the archived app's generated
privacy report before submission, because SDK upgrades can change these
answers.

**These values must be entered and rechecked manually for every release that
changes them.** The questionnaire is not part of the build and is not generated
from this file. A build submitted against answers made for an earlier version
would be a misdeclaration.

## Other App Store Connect fields

- **Category** — Developer Tools. Secondary is optional; Utilities fits.
- **Content rights** — the app contains no third-party content: **No**.
- **Copyright** — `2026 Keisuke Nishitani`
- **Price** — Free.
- **Privacy policy URL** — `https://keinstn.github.io/drover/privacy`
- **Support URL** — `https://keinstn.github.io/drover/support`
- **Screenshots** — `site/public/screenshots/{en,ja}/`, four per locale. See
  below; the app is iPhone-only, so no iPad sizes are required. They carry no
  caption overlays, so nothing in them repeats the name or has to be re-rendered
  when the store copy changes.

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
