# Push notifications

Drover sends notifications through Firebase Cloud Messaging (FCM). The
`drover.notify` Herdr plugin sends only `blocked` agent status changes; it does
not send `done` events.

## Backend prerequisites

Complete [Firebase and Google Cloud setup](firebase-setup.md), including
Functions deployment and the Firestore TTL policy, before pairing a host.

## Manually install and pair the plugin

This is intentionally a manual host operation. The app never installs or
updates executable code on the Herdr host.

The host needs Herdr 0.7.0 or newer and Node.js 18 or newer. Make the Drover
checkout available on the host, then link the plugin:

```sh
herdr plugin link /path/to/drover/plugins/drover-notify
```

In Drover, open the host settings and select **Create notification pairing
code**. The dialog provides copy buttons for the plugin-link command, the setup
command, the pairing code, and the completion URL. The code is valid for ten
minutes.

Run the setup command on the host after linking the plugin:

```sh
node /path/to/drover/plugins/drover-notify/bin/setup.mjs \
  --completion-url 'paste-the-completion-url-from-Drover' \
  --herdr-bin "$HOME/.local/bin/herdr"
```

The script securely prompts for the pairing code, obtains the plugin's
Herdr-managed config directory, and writes the host credential to
`$config_dir/config.json` atomically with owner-only permissions. Do not copy
this file between hosts or commit it. Pairing again rotates the credential for
the same host ID. Resetting the host in Drover, or changing its address, port,
or SSH user, revokes the previous host credential before saving the new
configuration.

## Verify delivery

Start an agent that enters a real blocked state. Herdr invokes
`pane.agent_status_changed`; the plugin sends only events whose
`agent_status` is `blocked`.

Inspect the plugin log on the host:

```sh
herdr plugin log list --plugin drover.notify
```

The notification data contains the paired `hostId`, `paneId`, and a unique
`eventId`. Drover rejects a notification whose `hostId` does not match its
saved host configuration, then opens the matching agent pane when the
notification is tapped.
