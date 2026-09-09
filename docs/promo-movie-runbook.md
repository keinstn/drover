# Drover promo movie runbook

A reproducible procedure for recording the promo movie (launching a pi agent
from Drover and chatting with it). On a macOS host, the Herdr terminal
(background) and Drover in the iOS Simulator (foreground) share one screen,
captured with `screencapture`.

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
   - "Please position the iOS Simulator so it doesn't cover the Herdr
     terminal"
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
   - Tap the agent card → tap the TextField → type the prompt →
     `send_message_button`
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
concatenate (record timestamps with `date +%s.%N` during the shoot and cut at
offsets from t0):

- Form filling: 5x speed
- Agent boot through prompt typing: 2.5x speed
- Prompt send through answer display: real time (includes a few seconds of
  hold after the answer)

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
- Agent name conflicts → the previous agent's name (e.g. `pi-main`) sticks
  around. pi titles itself `π - <dir>`, so collisions are mostly harmless.
- SIGINT to `screencapture` is ignored. Always auto-stop via `-V`.
- Restoring the tab during recording gets captured on film. Restore only
  after recording stops.
- The app renders the answer 2–5 seconds after the agent finishes. Keep the
  recording running 8–10 extra seconds past completion.
