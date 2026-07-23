import assert from "node:assert/strict";
import test from "node:test";

import { blockedEventFromEnvironment } from "../src/event.mjs";

void test("accepts a blocked status event", () => {
  assert.deepEqual(
    blockedEventFromEnvironment({
      HERDR_PLUGIN_EVENT_JSON: JSON.stringify({
        event: "pane_agent_status_changed",
        data: {
          type: "pane_agent_status_changed",
          pane_id: "workspace:pane",
          agent_status: "blocked",
          display_agent: "Claude",
        },
      }),
    }),
    { paneId: "workspace:pane", agentName: "Claude" },
  );
});

void test("ignores non-blocked status events", () => {
  assert.equal(
    blockedEventFromEnvironment({
      HERDR_PLUGIN_EVENT_JSON: JSON.stringify({
        event: "pane_agent_status_changed",
        data: {
          type: "pane_agent_status_changed",
          pane_id: "workspace:pane",
          agent_status: "done",
        },
      }),
    }),
    null,
  );
});
