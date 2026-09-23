## [1.1.0] - 2026-09-23

### 🚀 Features

- *(app)* Add the voice assistant foundation (Gemini Live, opt-in) (#227)
- *(app)* Voicemail-and-callback flow for the voice assistant (#228)
- *(app)* Ground voice message sending in two-step drafts (#229)
- *(app)* Resume the voice session across Live connection drops (#235)
- *(app)* Launch an agent by voice through a two-step draft (#236)
- *(app)* Enable barge-in on release builds (#237)
- *(app)* Answer multi-question AskUserQuestion prompts by voice (#240)
- *(app)* Gate the voice assistant on consent and cap a session (#254)
- *(app)* Move the voice entry point beside the launch FAB (#258)
- *(app)* Redesign the voice assistant as a stage (#259)
- *(app)* Ship the voice assistant on, and make its toggle a real revoke (#260)
- *(app)* Make the voice orb follow the voice (#261)
- *(app)* Make the voice screen a transcript lit from its bottom edge (#262)
- *(app)* Light the voice screen in both themes, and brighter (#263)
- *(app)* Keep the screen awake during a voice session, and end it on background (#265)
- *(app)* Open the voice session on a server-minted Live token (#267)
- *(app)* Route voice sessions through the minted token (#268)
- Sell a call, not a minute — shorten the cap and outlive it (#269)
- *(app)* Read what a voice call billed for, on the device (#270)
- *(app)* Link an Apple ID to the account, before anything hangs off it (#272)
- *(app)* Continue a voice call instead of dropping it (#275)
- *(app)* Keep a voice call listening across drover (#276)
- *(voice)* Charge a voice call against a credit wallet (#274)
- *(app)* Let someone delete their account from inside drover (#279)
- *(app)* Show the account what its voice credits are doing (#280)
- *(voice)* Show the herd under the voice screen's header (#281)
- *(voice)* Make a new call wait for a tap on the voice screen (#282)
- *(voice)* Say what else the call can do before it starts (#284)
- *(voice)* Tell the model which agent's screen is open (#285)
- *(voice)* Move to the stable Live model and make compression fire (#289)
- *(settings)* Nudge to re-pair hosts right after account deletion (#293)
- *(voice)* Cap the free campaign and grant its credits (#294)
- *(voice)* Show what a call costs and what is left (#295)
- *(voice)* Toast the free credits an Apple sign-in just granted (#298)
- *(voice)* Let someone say they would pay, once the free calls run out (#299)
- *(app)* Label the voice assistant as experimental in-app (#305)

### 🐛 Bug Fixes

- *(app)* Gate the mic until the echo canceller has warmed up (#242)
- *(app)* Stop leaking host stderr and inline code to Gemini (#255)
- *(app)* Say both sides of a voice call are transcribed (#257)
- *(app)* Report usage when a call ends in error too (#271)
- *(voice)* Keep a parked call that still has its credit (#283)
- Stop agent launches colliding on the herdr agent name (#286)
- *(voice)* Re-anchor the pinned drafts on a new card (#287)
- *(voice)* Recover from audio session interruptions (#297)
- *(voice)* Delete a deleted account's voice session records (#300)
- *(app)* Build Sign in with Apple to Apple's button spec (#301)
- Bound voice token reuse and correct privacy docs (#303)

### 🚜 Refactor

- *(voice)* Drop the Firebase AI Logic fallback transport (#290)

### 📚 Documentation

- Describe the voice-live rebase, not a merge
- Document voice billing visibility and the credits design (#252)
- Disclose the Gemini voice data flow in the privacy policy (#256)
- Record what Gemini Live reports as usage (#264)
- Record that an ephemeral token can gate a voice session (#266)
- *(voice-billing)* Draw the four flows the wallet has to implement (#273)
- *(app)* The mint is no longer free to fall back from (#278)
- Say what Firebase AI Logic is still for (#291)
- Describe the voice path the app actually takes (#292)
- Disclose the voice wallet, ledger and session record (#296)
- Retire the voice-live branch machinery

### 🧪 Testing

- *(app)* Scroll to the version row before asserting on it

### ⚙️ Miscellaneous Tasks

- Set up the voice-live integration branch (#226)
- *(tool)* Let the live probes vary model, compression and system prompt (#288)
## [1.0.6] - 2026-09-22

### 🚀 Features

- Notify on agent done and let each device opt in or out (#239)
- *(app)* Flag an out-of-date notification plugin in settings (#243)
- *(app)* Replace iOS app icon (#244)
- *(app)* Replace iOS app icon (#251)

### 🐛 Bug Fixes

- *(functions)* Make done notifications opt-in, and raise the plugin floor to 0.2.0 (#247)
- *(app)* Reuse the live herdr connection for the settings plugin probe (#248)

### 📚 Documentation

- Drop the restated drover-notify herdr floor (#241)

### ⚙️ Miscellaneous Tasks

- *(app)* Upgrade flutter sdk to 3.47.4 (#246)
## [1.0.5] - 2026-09-13

### 🚀 Features

- *(app)* Reconnect fast after a network change (#222)
- *(app)* Invalidate stale SSH transport on app resume (#224)
- *(app)* Compact the launch-agent sheet with a chip/segmented layout (#225)

### 🐛 Bug Fixes

- *(site)* Remove two visible gaps in the Japanese support page (#212)
- *(app)* Anchor the key-row refresh debounce to send completion (#220)
- *(app)* Stop raw keys interleaving into a multi-step send (#221)
- *(app)* Retry host-platform detection after a failure (#223)

### 🚜 Refactor

- *(app)* Route key row's Esc and Enter through the key queue (#219)

### 📚 Documentation

- Add promo movie recording runbook (#213)
- Correct the promo movie runbook from a real shoot (#214)
- Drop the incorrect claim about preset and chat rendering (#215)
- Add a demo GIF to the README (#216)
## [1.0.4] - 2026-09-09

### 🚀 Features

- *(app)* Redesign the UI onto herdr-family ink tokens (#205)
- *(app)* Drop the accent hue for ink (#206)
- *(app)* Restore the rounded geometry (#208)
- *(site)* Show the app's screenshots on the home page (#209)
- *(site)* Add a Japanese locale (#210)
- *(app)* Show the app version in settings, copyable (#211)

### 🐛 Bug Fixes

- *(app)* Give the mono seam a real face, and refresh the screenshots (#207)

### ⚙️ Miscellaneous Tasks

- *(app)* Upgrade flutter sdk to 3.47.2 (#204)
## [1.0.3] - 2026-09-07

### 🚀 Features

- *(app)* Add a collapsible arrow-key row to the agent composer (#191)
- *(agents)* Add omp agent support (#192)

### 🐛 Bug Fixes

- *(app)* Move Esc and Enter into the collapsible key row (#195)
- *(functions)* Bump firebase-admin to 14.3.0, drop unused firebase-functions-test (#202)

### 📚 Documentation

- *(copilot)* Record herdr 0.8.2's own Copilot focus fix (#193)
- *(herdr)* Note herdr 0.8.2 fixes #1561, keep raw-backtab workaround (#194)

### 🧪 Testing

- *(app)* Add unit coverage for FirebasePushMessaging.requestAuthorization (#203)

### ⚙️ Miscellaneous Tasks

- *(app)* Align firebase-ios-sdk versions across firebase packages (#199)
## [1.0.2] - 2026-09-06

### 🚀 Features

- *(app)* Add pi agent support (#179)

### ⚙️ Miscellaneous Tasks

- *(app)* Check iOS SPM dependency resolution on macOS (#178)
## [1.0.1] - 2026-08-27

### 🐛 Bug Fixes

- Disable host setup text scanning (#150)
- *(app)* [**breaking**] Name herdr as down instead of blaming the connection (#167)
- *(app)* Align Firebase iOS SDK SPM pins on 12.17.0 (#177)

### ⚙️ Miscellaneous Tasks

- Split ci.yml into per-path flutter and functions workflows (#165)
- *(release)* Decouple CHANGELOG/tagging from starting a build (#166)
## [1.0.0] - 2026-07-30

### 🚀 Features

- Stage 1 foreground MVP — connect, herd list, agent supervise (#1)
- Add herdr→ntfy push plugin for blocked/done alerts (#2)
- Launch agents from the herd screen (#4)
- Show workspace labels in agent views (#5)
- Stop agents from herd list (#7)
- Colorize agent transcript, add mode badge, refine composer (#8)
- Cycle a running agent's mode from the agent screen (#10)
- Show notifications as top toasts instead of bottom snackbars (#12)
- *(app)* Add pi and oh-my-pi agent presets (#13)
- *(app)* Add on-device voice input (#14)
- *(app)* Let users edit the agent name when launching (#17)
- *(app)* Send images to a Claude Code agent (#18)
- *(app)* Surface SSH auth notices (e.g. Tailscale SSH login URL) (#22)
- *(app)* Pull down to load older transcript lines (#23)
- *(app)* Stage and send multiple images at once (#25)
- *(app)* Improve workspace launch UX (#30)
- *(app)* Add Japanese/English localization foundation (#29)
- *(app)* Give the message composer a full-width text field (#28)
- *(app)* Localize remaining screens for Japanese/English (#31)
- *(app)* Browse remote directories when picking a working dir (#33)
- *(app)* Rework agent composer input controls (#37)
- *(app)* Pick multiple gallery photos at once (#38)
- *(app)* Load Claude native transcript history (#39)
- *(app)* Add herd long-press rename for workspace and agents (#47)
- *(app)* Add host setup preview (#48)
- *(app)* Render native Claude history as a markdown chat (#51)
- *(app)* Replace auto-generated theme with the Ink dark color scheme (#52)
- *(app)* Syntax-highlight fenced code and scale chat headings (#53)
- *(app)* Render tool calls and thinking as collapsible transcript chips (#54)
- *(app)* Answer AskUserQuestion prompts from a bottom sheet (#55)
- *(app)* Scroll the live terminal horizontally instead of re-wrapping (#56)
- *(app)* Compact the AskUserQuestion answer sheet (#57)
- *(app)* Add an always-available Esc button to the composer (#59)
- *(app)* Label the mode-switch button and fix its colors (#61)
- *(app)* Add Copilot mode support (#63)
- *(app)* Add Copilot image attachments (#64)
- *(app)* Add Copilot native history (#65)
- *(app)* Answer Copilot structured prompts (#66)
- *(app)* Preserve agent compose draft across navigation (#72)
- *(app)* Add Codex agent adapter (#85)
- *(herd)* Use terminal_title_stripped as the session title (#87)
- Add secure blocked-agent push notifications (#91)
- *(app)* Split accept-edit, auto, and bypass into distinct modes (#92)
- *(notifications)* Auto-pair the drover.notify plugin when detected (#94)
- *(app)* Warm redesign with light/dark themes and agent switcher bar (#93)
- *(app)* List every preview scenario as a tappable gallery entry (#97)
- *(security)* Verify SSH host key (TOFU) and harden key storage (#98)
- *(errors)* Friendly, localized error messages with details (#99)
- *(validation)* Validate port, private key, launch fields, and image ext (#100)
- *(host)* Support windows herdr hosts in the command path (#103)
- *(host)* Locate transcripts and stage images on windows hosts (#104)
- *(app)* Add an always-available Enter button to the composer (#105)
- *(host)* Pair the notify plugin on windows herdr hosts (#108)
- *(app)* Support multiple herdr hosts with quick switching (#110)
- *(app)* Aggregate all hosts in the herd view (#111)
- *(herdr)* Enforce minimum supported herdr version before starting agents (#115)
- *(app)* Add language and theme settings (#119)
- *(app)* Replace iOS app icon (#127)
- *(app)* Replace iOS app icon (#128)
- *(app)* Replace iOS app icon (#129)
- *(theme)* Neutralize light theme surface chroma to match the app icon (#130)
- *(theme)* Take the light neutrals to near-achromatic and de-beige idle (#133)
- *(theme)* Move the light theme onto iOS's cool neutral axis (#134)
- *(theme)* Make the light page pure white and clear the last warm leftovers (#135)
- *(app)* Promote the stub herdr backend into a demo mode (#138)
- *(app)* Complete the demo mode into a real intro for new users (#142)
- *(site)* Add a public VitePress site with privacy policy and support pages (#143)
- Add App Store submission assets — screenshots and store copy (#146)
- Install drover-notify from GitHub now that the repo is public (#147)

### 🐛 Bug Fixes

- Surface transport failures + add push-config self-test (#3)
- *(app)* Open host setup from settings gear and add host reset (#21)
- *(app)* Keep uploaded images out of git with a self-ignoring .drover (#26)
- *(app)* Bypass shell aliases for find and mkdir over SSH (#41)
- *(app)* Serialize SSH channel operations on the shared connection (#42)
- *(app)* Close leaked SFTP channels on the shared SSH connection (#43)
- *(app)* Add explicit cancel button to launch agent sheet (#45)
- *(app)* Treat missing Claude transcript as no history (#46)
- *(app)* Tolerate a transient null agent label in the herd list (#67)
- *(app)* Preserve Copilot mode control after footer wrap (#68)
- *(app)* Load Copilot history from fish hosts (#69)
- *(app)* Retain mode control in Copilot autopilot (#70)
- *(app)* Hide iOS Scan Text button in text field menus (#71)
- *(app)* Show agent output before native history (#74)
- *(app)* Deliver prompts via herdr `agent prompt` (#79)
- *(app)* Keep prompts landing on backgrounded Copilot panes (#80)
- *(app)* Remove pi agent launch options (#81)
- *(app)* Support herdr 0.7.5 CLI contracts (#82)
- *(app)* Render task_complete summary as assistant text (#84)
- *(app)* Retry agent start on transient agent_pane_busy race (#86)
- *(speech)* Select Japanese recognition locale (#88)
- *(agent)* Use build icon for tool-use chip (#89)
- *(mcp)* Run dart mcp-server via fvm (#90)
- *(app)* Show notification toasts via the navigator overlay (#95)
- *(app)* Prune stale .drover image uploads on send (#96)
- *(security)* Clear stale keychain entry before writing host_config (#101)
- *(app)* Swap Esc and Enter button positions in agent composer (#112)
- *(app)* Include command, exit code, and stderr in herdr parse-error messages (#113)
- *(herdr)* Recognize error envelopes on stderr regardless of exit code (#114)
- *(app)* Bound native-history dedup check to a recent-character window (#116)
- *(ssh)* Bound connection stalls and clarify lost-connection errors (#117)
- *(app)* Let pull-to-load-more wait for an in-flight native-history load (#120)
- *(ssh)* Bound the SSH auth handshake wait in SshCommandRunner._connect() (#124)
- *(notifications)* Strip the extended-length prefix from plugin_root (#125)
- Accept UUIDv7 native transcript sessions (#131)
- *(ios)* Declare non-exempt encryption for the bundled ssh implementation (#136)
- *(functions)* Backend hardening — concurrency bound, revokeHost ownership filter, agentName sanitization (#137)
- *(app)* Give the demo session a real UUID so its chat transcript renders (#139)
- *(ios)* Drop ITSAppUsesNonExemptEncryption instead of pre-declaring it (#144)

### 🚜 Refactor

- *(app)* Add agent capability adapters (#60)
- *(app)* Prepare agent adapter foundations (#83)
- *(plugins)* Remove drover-notify plugin, now its own repo (#121)

### 📚 Documentation

- Rewrite README around the mobile agent-development concept (#19)
- Note herdr claude integration requirement for full history (#40)
- Split per-agent CLI notes out of herdr-notes (#78)
- *(readme)* Note Windows OpenSSH admin authorized_keys location (#109)
- Record which Media Manager section takes the screenshots (#148)
- Rename the store listing and move Herdr out of the app name (#149)

### ⚡ Performance

- *(app)* Bound native transcript loading (#75)
- *(app)* Virtualize agent transcript rendering (#76)

### ⚙️ Miscellaneous Tasks

- Scaffold drover flutter app + stage 0 ssh spike
- Add dev harness (lint, task runner, ci, mcp, format hook)
- Enable Marionette in debug builds (#6)
- *(app)* Add a stubbed UI preview harness (#32)
- *(app)* Consolidate UI previews into one registry entrypoint (#34)
- *(app)* Add Xcode Cloud post-clone script for TestFlight delivery (#35)
- *(app)* Source build number from pubspec instead of Xcode Cloud counter (#36)
- *(app)* Use dartssh2 v2.22.3 (#49)
- *(app)* Remove temporary agent presets (#50)
- Remove unused notification plugin (#73)
- *(app)* Bump build number to 15
- *(app)* Bump build version to 18
- *(app)* Bump build version to 19
- *(app)* Bump build version to 20
- *(spike)* Add winprobe command for windows host probing (#102)
- *(app)* Bump build number to 21
- *(app)* Bump build version to 24
- *(ios)* Restrict app to iPhone-only device family (#132)
- Add MIT license (#140)
- *(app)* Make the preview harness usable for App Store screenshots (#141)
- Make App Store screenshot capture reusable (#145)
- Add a just release recipe that starts the Xcode Cloud build (#151)
- Enable Dependabot for pub, npm, and GitHub Actions (#152)

### ◀️ Revert

- *(app)* Restore live terminal line wrapping (#58)
