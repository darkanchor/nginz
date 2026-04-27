/**
 * Semantic validation for redis benchmark scenarios.
 *
 * Before trusting benchmark numbers, confirm each scenario endpoint returns
 * the expected JSON shape and the payload is parseable.
 */
export async function validateScenario(baseUrl, scenario) {
  const url = `${baseUrl}${scenario.path}`;
  const res = await fetch(url, { method: "GET" });
  if (res.status !== 200) {
    return { ok: false, error: `HTTP ${res.status}`, scenario: scenario.name };
  }

  const contentType = res.headers.get("content-type") || "";
  if (!contentType.includes("application/json")) {
    return { ok: false, error: `unexpected content-type: ${contentType}`, scenario: scenario.name };
  }

  let body;
  try {
    body = await res.json();
  } catch {
    return { ok: false, error: "response is not valid JSON", scenario: scenario.name };
  }

  if (typeof body !== "object" || body === null) {
    return { ok: false, error: "response is not an object", scenario: scenario.name };
  }

  // Redis GET response: { "value": "..." } or { "value": null }
  if (!("value" in body)) {
    return { ok: false, error: 'response missing "value" key', scenario: scenario.name };
  }

  return { ok: true, scenario: scenario.name, valueType: typeof body.value };
}
