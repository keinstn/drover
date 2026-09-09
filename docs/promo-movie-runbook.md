# Drover promo movie runbook

A reproducible procedure for recording the promo movie (launching a pi agent
from Drover and watching it work). On a macOS host, the Herdr terminal
(background) and Drover in the iOS Simulator (foreground) share one screen,
captured with `screencapture`.

pi does not report an agent session to Herdr, so Drover renders its pane-text
fallback: the shot shows the live-terminal view, not chat bubbles. The
`claude` preset is what renders chat, so the preset choice decides which UI
the promo shows.

## Prerequisites

- The agent running this runbook must itself live in a Herdr-managed pane
  (`HERDR_ENV=1`).
- A simulator prepped with `just sim-prep en` (status bar pinned to 9:41).
- Marionette MCP (`marionette_mcp`) registered with the agent CLI.

## One-time setup

```sh
# Clone the repo for the shoot (keeps personal paths off screen)
git clone --local "$(git rev-parse --show-toplevel)" /tmp/drover

# The movie workspace (the label is picked from a dropdown later)
herdr workspace create --cwd /tmp/drover --label 'Drover Promo' --no-focus

# Run the app on the simulator in debug mode; note the VM service URI
cd app && nohup fvm flutter run -d <udid> >/tmp/drover-promo-flutter.log 2>&1 &
grep -aoE 'ws://[^ ]+/ws' /tmp/drover-promo-flutter.log | tail -1
```

Connect `marionette_connect` to that URI and confirm Drover already has a
host (localhost) configured.

## Shooting flow (collaboration with the human)

Order matters. Focusing the movie tab hides the conversation pane, so
**switch tabs only after the user replies**.

1. **Prepare (do not touch the tab — stay on the conversation side)**
   - Confirm the simulator is running
   - Return Drover to the herd list (tap back if an agent screen is open)
   - Verify the connection with `marionette_connect`
2. **Ask the user and wait**
   - "Please position the iOS Simulator so it leaves the agent pane
     visible" — the agent pane is the right-hand pane of the split, and the
     Simulator covering the left-hand shell pane is fine (that is what a
     good frame looks like)
   - They can reply in the conversation pane (the tab never switches)
3. **Once they reply, start the shoot**
   - **Bring the Simulator to front** (`open -a Simulator`) — typing a reply
     brought the terminal to front, so this must be re-done here
   - Switch to the movie tab with `herdr tab focus <movie-tab>`
   - Start `screencapture -v -V<N> -k <raw>.mov` in the background (it
     auto-stops after `-V` seconds)
4. **Drive the app** (marionette; one call at a time — batched calls have
   been observed failing partway)
   - `launch_agent_fab` → `preset_pi` → enter `/tmp/drover` into `cwd_field`
   - `ws_mode_existing` → `ws_dropdown` → `Drover Promo` → `launch_button`
   - Poll for the pane with `herdr pane list --workspace <movie-ws>`
   - The new agent pane is the tab's non-focused pane in a split. Run
     `herdr agent focus <pane>` before driving it — it looks better on film
     and avoids keystrokes going to the wrong pane
   - Tap the agent card → `enter_text` the prompt against the parent
     `agent_composer` key (the composer TextField has no key, so there is
     nothing to match on it) → `send_message_button`
   - Wait for completion with `herdr agent wait <pane> --timeout 60000`,
     then keep recording a few extra seconds
5. **Stop and clean up**
   - SIGINT does not stop `screencapture`; wait for the natural `-V` end
   - Restore the conversation tab with `herdr tab focus <conversation-tab>`
   - Exit the recorded agent with `ctrl+d` → `pane close` to leave the
     workspace clean

## Example prompt (short, and shows the agent reading the repo)

> Look at this repo and answer in 2-3 sentences: what is drover and how does it talk to a Herdr host?

## Editing (ffmpeg)

Split the raw recording into three segments with different speeds and
concatenate:

- Form filling: 5x speed
- Agent boot through prompt typing: 2.5x speed
- Prompt send through answer display: real time (includes a few seconds of
  hold after the answer)

`screencapture` starts recording roughly 6 seconds after it is launched, so
timestamps taken with `date +%s.%N` during the shoot are all shifted and every
offset from t0 lands late: on this shoot the LAUNCH tap stamped at wall
+47.45s appeared at video ~42s, and the prompt send stamped at wall +97.23s
appeared at video ~93s. Treat the wall offsets as a starting search point
only, then confirm each cut point (`A0`, `A1`, `B1`, `B2`) by extracting
frames:

```sh
ffmpeg -v error -ss <t> -i raw.mov -frames:v 1 frame.png
```

```sh
ffmpeg -y -i raw.mov -filter_complex \
"[0:v]trim=start=A0:end=A1,setpts=(PTS-STARTPTS)/5,fps=30,scale=1920:-2,format=yuv420p[a];\
[0:v]trim=start=A1:end=B1,setpts=(PTS-STARTPTS)/2.5,fps=30,scale=1920:-2,format=yuv420p[b];\
[0:v]trim=start=B1:end=B2,setpts=(PTS-STARTPTS),fps=30,scale=1920:-2,format=yuv420p[c];\
[a][b][c]concat=n=3:v=1:a=0[v]" \
-map "[v]" -c:v libx264 -preset medium -crf 20 -movflags +faststart out.mp4
```

## Known pitfalls

- `launch_button` stays disabled → `cwd_field` is empty (selecting an
  existing workspace does not prefill the cwd). Always type it in.
- `ws_dropdown` does not exist until `ws_mode_existing` has been tapped.
  Out of order, marionette fails with "not found" — a different symptom from
  the disabled `launch_button` above.
- Agent name conflicts → the previous agent's name (e.g. `pi-main`) sticks
  around. pi titles itself `π - <dir>`, so collisions are mostly harmless.
- SIGINT to `screencapture` is ignored. Always auto-stop via `-V`.
- Restoring the tab during recording gets captured on film. Restore only
  after recording stops.
- Verify the capture is actually recording about a second after starting it
  (`pgrep -fl screencapture`, plus checking the output file is growing).
  Under `nohup` a bad output path fails silently, and since SIGINT is ignored
  the only way out is `kill -9` and a restart.
- Sizing `-V`: this shoot used `-V 240` and the usable action ran about 130
  seconds.
- The app renders the answer 2–5 seconds after the agent finishes. Keep the
  recording running 8–10 extra seconds past completion.
