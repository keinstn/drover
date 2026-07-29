# Push notifications

Drover sends notifications through Firebase Cloud Messaging (FCM). The
`drover.notify` Herdr plugin sends only `blocked` agent status changes; it does
not send `done` events.

## Backend prerequisites

Complete [Firebase and Google Cloud setup](firebase-setup.md), including
Functions deployment and the Firestore TTL policy, before pairing a host.

## Manually install the plugin

Installing the plugin is intentionally a manual host operation. The app never
installs or updates executable code on the Herdr host.

The plugin lives in its own repo,
[`keinstn/drover-notify`](https://github.com/keinstn/drover-notify). The host
needs Herdr 0.7.5 or newer and Node.js 18 or newer. Install it on the host:

```sh
herdr plugin install keinstn/drover-notify
```

`herdr plugin install` fetches over unauthenticated HTTPS, which is why this is
the one-line path now that the repo is public.

drover-notify's own README says Herdr 0.7.0, which is right for the plugin by
itself. The floor above is drover's — `kMinHerdrVersion` in
`app/lib/src/herdr/herdr_version.dart` is `(0, 7, 5)` — because below it drover
still reads and steers agents but refuses to start them. **Do not lower this
number to match the plugin's README.**

If you would rather run your own checkout — a fork, or a branch you are testing
— clone it and link that instead:

```sh
git clone https://github.com/keinstn/drover-notify.git
herdr plugin link /path/to/drover-notify
```

## Pair the plugin

In Drover, open the host settings and select **Create notification pairing
code**.

- **If the plugin is already linked and enabled**, Drover detects it (via
  `herdr plugin list --plugin drover.notify --json` over the host's existing
  SSH connection) and asks for confirmation before pairing automatically: it
  requests a pairing code, then runs the plugin's own `bin/pair.mjs` over SSH
  — piping the code through stdin, never as a process argument — to write the
  host credential itself. No host terminal step is needed. If the automatic
  attempt fails for any reason (or you cancel the confirmation), Drover falls
  back to the manual flow below with the same pairing code.
- **If the plugin is not yet linked**, Drover shows the manual dialog directly.
  It provides copy buttons for the plugin-link command, the setup command, the
  pairing code, and the completion URL. The code is valid for ten minutes.

  Run the setup command on the host after linking the plugin:

  ```sh
  node /path/to/drover-notify/bin/setup.mjs \
    --completion-url 'paste-the-completion-url-from-Drover' \
    --herdr-bin "$HOME/.local/bin/herdr"
  ```

  The script securely prompts for the pairing code, obtains the plugin's
  Herdr-managed config directory, and writes the host credential to
  `$config_dir/config.json` atomically with owner-only permissions.

Either path writes the same `$config_dir/config.json`, atomically and with
owner-only permissions. Do not copy this file between hosts or commit it.
Pairing again (manual or automatic) rotates the credential for the same host
ID. Resetting the host in Drover, or changing its address, port, or SSH user,
revokes the previous host credential before saving the new configuration.

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
