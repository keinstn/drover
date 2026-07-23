# Push notifications

Drover sends notifications through Firebase Cloud Messaging (FCM). The
`drover.notify` Herdr plugin sends only `blocked` agent status changes; it does
not send `done` events.

## Deploy the backend

The Firebase project needs Anonymous Authentication, Firestore, Cloud
Messaging, and the Apple APNs configuration described in the root README.
Deploy the Functions after selecting the Firebase project:

```sh
firebase deploy --only functions
```

The `sendBlockedNotification` Function creates
`hosts/{hostId}/events/{eventId}` documents to deduplicate plugin retries. In
Firestore, configure a TTL policy for the `expiresAt` field in that collection
group so these one-day deduplication records are removed automatically.

## Manually install and pair the plugin

This is intentionally a manual host operation. The app never installs or
updates executable code on the Herdr host.

The host needs Herdr 0.7.0 or newer and Node.js 18 or newer. Make the Drover
checkout available on the host, then link the plugin:

```sh
herdr plugin link /path/to/drover/plugins/drover-notify
```

In Drover, open the host settings and select **Create notification pairing
code**. The dialog displays a one-time pairing code, host ID, and completion
URL. The code is valid for ten minutes.

On the host, save the code in a securely created temporary owner-only file,
then pair the plugin. Keeping it out of command-line arguments avoids exposing
it in shell history or process listings. After `cat` starts, paste the code and
press Control-D.

```sh
pairing_file="$(mktemp)"
chmod 600 "$pairing_file"
trap 'rm -f "$pairing_file"' EXIT
cat > "$pairing_file"
config_dir="$(herdr plugin config-dir drover.notify)"
node /path/to/drover/plugins/drover-notify/bin/pair.mjs \
  --completion-url 'paste-the-completion-url-from-Drover' \
  --config-dir "$config_dir" < "$pairing_file"
```

`pair.mjs` receives a host credential from the backend and writes it to
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
