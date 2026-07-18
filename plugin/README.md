# drover.ntfy-push

A [Herdr](https://herdr.dev) plugin that pushes a phone notification via
[ntfy](https://ntfy.sh) when a coding agent in one of your Herdr panes goes
`blocked` (needs input) or `done` (finished). It complements Drover's
foreground app — this is the "app is closed, still get pinged" piece.

## Install

For local development, link the plugin directory straight from a checkout:

```sh
herdr plugin link /path/to/drover/plugin
```

Once published, install it from a repo/subdir with:

```sh
herdr plugin install <owner>/<repo>/plugin
```

(Run `herdr plugin --help` for the full command reference.)

## Configure

The plugin is inert (sends nothing) until it has a topic. Copy the example
config and edit it:

```sh
mkdir -p ~/.config/drover-push
cp config.example ~/.config/drover-push/config
$EDITOR ~/.config/drover-push/config
```

Set `NTFY_TOPIC` to a long, random string — treat it like a shared secret.
`NTFY_SERVER` defaults to `https://ntfy.sh`; set it if you self-host ntfy.

## Subscribe on your phone

Install the [ntfy app](https://ntfy.sh/#subscribe) (iOS/Android) and
subscribe to the same topic you set above.

## Security note

Anyone who knows a public `ntfy.sh` topic name can subscribe and read its
notifications — there's no access control beyond obscurity of the topic
string. Use a long random topic, or self-host ntfy and point `NTFY_SERVER`
at it.

## Behavior

Notifies only on `pane.agent_status_changed` events where `agent_status` is
`blocked` (priority `high`, tag `warning`) or `done` (priority `default`, tag
`white_check_mark`). All other statuses (`working`, `idle`, `unknown`) are
ignored. Failures (missing config, network errors, herdr enrichment errors)
are swallowed silently — the hook always exits 0.
