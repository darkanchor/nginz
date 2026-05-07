async function parseJsonOrThrow(response, context) {
  const text = await response.text();
  try {
    return text.length === 0 ? null : JSON.parse(text);
  } catch (error) {
    throw new Error(`Invalid JSON for ${context}: ${error.message}\n${text.slice(0, 200)}`);
  }
}

export async function validateRuntime(context) {
  const stateRes = await fetch(`${context.baseUrl}/dynamic-upstreams`);
  if (stateRes.status !== 200) {
    return { ok: false, error: `dynamic-upstreams state returned HTTP ${stateRes.status}` };
  }
  const state = await parseJsonOrThrow(stateRes, "dynamic-upstreams state");
  if (state.target !== context.upstreamName) {
    return { ok: false, error: `unexpected upstream target ${state.target}` };
  }
  if (state.peer_count < 2) {
    return { ok: false, error: `expected at least 2 active peers, got ${state.peer_count}` };
  }

  const eventsRes = await fetch(`${context.baseUrl}/worker-events?channel=${encodeURIComponent(context.eventsChannel)}`);
  if (eventsRes.status !== 200) {
    return { ok: false, error: `worker-events returned HTTP ${eventsRes.status}` };
  }
  const events = await parseJsonOrThrow(eventsRes, "worker-events");
  if (!Array.isArray(events.events)) {
    return { ok: false, error: "worker-events response missing events array" };
  }

  const healthRes = await fetch(`${context.baseUrl}/health`);
  if (healthRes.status !== 200) {
    return { ok: false, error: `health status returned HTTP ${healthRes.status}` };
  }

  return { ok: true };
}

export async function validateScenario(context, scenario) {
  const result = await scenario.execute(context, 0);
  if (result.status !== 200) {
    return { ok: false, error: `${scenario.name} returned HTTP ${result.status}` };
  }
  if (result.payloadBytes <= 0) {
    return { ok: false, error: `${scenario.name} returned an empty payload` };
  }
  return { ok: true };
}
