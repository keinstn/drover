---
titleTemplate: false
---

# Privacy Policy — Drover

**Effective date:** 2026-07-28
**Developer:** Keisuke Nishitani
**Contact:** kei.sj.nstn@gmail.com

## The short version

Drover connects your device **directly to your own computer** over SSH. The
developer operates no server in that path and cannot see what passes through it.
Your agent transcripts, the commands you send, your source code, and your file
contents never reach the developer.

The only developer-operated service is the **optional push-notification
backend**, which exists so your device can be told that an agent is waiting for
you. What it stores is listed in full below.

Drover contains no analytics, no advertising, no tracking, and no third-party
SDKs that collect data about you. Nothing is sold or shared for marketing.

## What Drover does not collect

Because Drover talks straight to your machine, the following never reach the
developer:

- Agent transcripts, chat history, and terminal output
- Commands, prompts, and follow-up messages you send to an agent
- Source code, diffs, file names, and file contents
- Names of your projects, hosts, workspaces, or repositories
- Photos or images you attach (these are uploaded over SSH to your own machine)
- Dictated audio (see "Dictation" below)
- Your SSH private key or its passphrase

There is no account to create. You never give Drover a name, an email address,
or an Apple ID.

## Data stored on your device only

The following is stored on your device and is never transmitted to the
developer:

- **SSH private key and passphrase** — held in the iOS Keychain. They are pinned
  to the device: they are not restored onto a new device from an encrypted
  backup.
- **Host connection settings** — hostname, port, username, the path to the
  `herdr` binary, and the host key fingerprint Drover pinned on first connect.
  Also held in the Keychain.
- **Preferences** — your theme and language choice.

Deleting the app removes all of this.

## The push-notification backend

Push notifications are **optional**. They only start working after you pair a
host, which is a deliberate action you take. If you never pair, no data about
you is stored on the backend at all.

The backend runs on Google Firebase (Authentication, Cloud Firestore, Cloud
Functions, and Cloud Messaging). It stores exactly the following:

| What | Why | How long |
|---|---|---|
| An **anonymous account identifier**, created automatically by Firebase Anonymous Authentication | To associate your devices with your paired hosts | Until you delete your data |
| **Push token** and **platform** for each registered device, plus timestamps | To deliver notifications to that device | Until the device is unregistered |
| For each paired host: the anonymous account identifier, a **SHA-256 hash** of the host's pairing credential, and timestamps | So the host can prove it is allowed to notify you. The credential itself is never stored | Until you revoke the host |
| **Pairing codes**, stored only as a SHA-256 hash, with the account identifier and host identifier | To complete a pairing you initiated | **Automatically deleted after 10 minutes** |
| **Notification de-duplication records** — timestamps only | So a repeated event does not notify you twice | **Automatically deleted after 24 hours** |
| **Rate-limit counters** — a request count and timestamps | To prevent abuse of the backend | Rolling window |

The anonymous account identifier is not linked to your name, email address, or
Apple ID. It identifies an installation of the app, not a person.

### What a notification actually contains

The notification text is a **fixed template**. It is not generated from your
agent's output:

> **Agent needs your input**
> `<agent name>` is blocked.

where `<agent name>` is the name of the coding agent (for example `claude`).
Alongside it, Drover sends identifiers so the app can open the right screen: an
event identifier, a host identifier, and a pane identifier.

**No transcript text, no code, no file paths, and no command text is included in
a notification, and none of it is stored on the backend.**

### Diagnostic logs

The backend writes operational logs containing host, pane, and event identifiers
and notification delivery counts, so that delivery failures can be diagnosed.
These logs contain **no notification content and no data from your machine**.
They are retained according to Google Cloud Logging's default retention.

## Dictation

Drover can transcribe speech so you can dictate a message to an agent.

**Speech recognition runs entirely on your device.** Drover requests on-device
recognition, and if your device cannot perform recognition on-device, **Drover
refuses to start dictation rather than sending your audio to a server.** No
audio recording leaves your device, and no audio or transcript is stored by the
developer.

The transcribed text becomes a message you choose to send to your own machine
over SSH.

## Camera and photo library

If you attach a photo, Drover uploads it over SSH to your own machine so the
agent can read it. The image does not pass through the developer's
infrastructure and is not stored by the developer.

## Verifying the app is genuine

Drover uses Firebase App Check with Apple's App Attest so the backend can
confirm a request came from a genuine, unmodified copy of the app. This involves
Apple's attestation service. It verifies the app, not you, and does not identify
you.

## Third parties

- **Google (Firebase)** — processes the notification-backend data listed above
  on the developer's behalf. See Google's privacy documentation for how Google
  handles data processed through Firebase.
- **Apple** — delivers push notifications through the Apple Push Notification
  service, and provides the App Attest attestation described above.

There are no other third parties. Drover contains no analytics SDK, no
advertising SDK, and no crash-reporting SDK.

## Tracking

Drover does not track you. It does not collect data for advertising, does not
build a profile of you, and does not share data with data brokers. It does not
use the Advertising Identifier and does not ask for tracking permission.

## Deleting your data

- **Revoke a host** in Drover to delete that host's record and its pairing
  credential hash from the backend.
- **Remove notifications for a device** to delete that device's push token.
- **Delete the app** to remove everything stored on the device, including your
  SSH key.
- To have any remaining backend record deleted, contact kei.sj.nstn@gmail.com.

Pairing codes and de-duplication records delete themselves on the schedule in
the table above without any action from you.

## Children

Drover is a developer tool. It is not directed at children and does not
knowingly collect data from children.

## Security

Connections to your machine use SSH with key-based authentication. Drover pins
your host's key on first connect and warns you if it changes. Your SSH private
key and passphrase are stored in the iOS Keychain. Backend requests are
authenticated and require App Attest verification, and the backend rejects all
direct client access to its database.

## Changes to this policy

Any change will be posted on this page with an updated effective date.

## Contact

kei.sj.nstn@gmail.com
