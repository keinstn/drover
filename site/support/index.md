---
titleTemplate: false
---

# Drover for Herdr — Support

Drover lets you supervise and steer AI coding agents running on your own
computer, from your phone.

**Contact:** kei.sj.nstn@gmail.com — this is the fastest way to reach the developer.
You can also open an issue at https://github.com/keinstn/drover/issues.

Please include your Drover version (Settings → About), your iOS version, and
what you were doing when the problem happened.

## What you need to use Drover

Drover is a client for a machine you already own. It does not work on its own.
You need:

1. **A computer running [Herdr](https://herdr.dev)** with your coding agents in
   it.
2. **SSH access to that machine with key-based authentication.**
   - macOS: System Settings → General → Sharing → Remote Login.
   - Windows: install the OpenSSH Server feature. For an **administrator**
     account the public key must go in
     `C:\ProgramData\ssh\administrators_authorized_keys`, not
     `~\.ssh\authorized_keys` — otherwise the connection fails with "All
     authentication methods failed".
3. **Herdr 0.7.0 or newer** on that machine.

If you just want to see what Drover does before setting any of this up, use the
demo on the setup screen. It runs entirely on your device with sample data.

## Common problems

**"Connection closed before authentication"**
If your host has Tailscale SSH enabled, its connection check can intercept the
SSH session before the operating system's SSH server ever sees it. Disable
Tailscale SSH for that machine, or connect over its regular SSH port.

**The transcript shows raw terminal text instead of a readable chat**
Drover reads your agent's own session history when a Herdr integration is
installed for that agent. Install one on the host:

```sh
herdr integration install claude
herdr integration install codex
herdr integration install copilot
```

An integration only takes effect for sessions started **after** you install it,
so start a fresh agent session afterwards. Without an integration, Drover falls
back to reading the terminal pane, which is bounded by how much scrollback Herdr
retains.

**An agent does not respond to what I send**
If the agent's pane is in a split tab and is not the active pane in that tab,
keystrokes can be dropped. Make that pane the active one in its tab.

**Dictation will not start**
Drover only uses on-device speech recognition. If your device cannot perform
recognition on-device, Drover will not fall back to server-based recognition, so
dictation is unavailable. Check that the recognition language is downloaded in
iOS Settings.

**Notifications do not arrive**
Notifications require pairing a host, which needs the `drover.notify` Herdr
plugin installed on that machine. See the notification setup documentation at
https://github.com/keinstn/drover. Only `blocked` events send a notification — Drover does not
notify you when an agent finishes.

## Privacy

Drover connects directly from your device to your own machine. Your transcripts,
commands, and code never reach the developer. See the
[privacy policy](https://keinstn.github.io/drover/privacy).

## Documentation

Full setup and command reference: https://github.com/keinstn/drover
