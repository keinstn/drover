export function blockedEventFromEnvironment(environment) {
  const raw = environment.HERDR_PLUGIN_EVENT_JSON;
  if (typeof raw !== "string") {
    throw new Error("HERDR_PLUGIN_EVENT_JSON is not set.");
  }

  let event;
  try {
    event = JSON.parse(raw);
  } catch {
    throw new Error("HERDR_PLUGIN_EVENT_JSON is not valid JSON.");
  }
  const data = event?.data;
  if (
    event?.event !== "pane_agent_status_changed" ||
    data?.type !== "pane_agent_status_changed" ||
    data?.agent_status !== "blocked" ||
    typeof data?.pane_id !== "string" ||
    data.pane_id.length === 0
  ) {
    return null;
  }
  const agentName =
    typeof data.display_agent === "string"
      ? data.display_agent
      : typeof data.agent === "string"
        ? data.agent
        : undefined;
  return { paneId: data.pane_id, agentName };
}
