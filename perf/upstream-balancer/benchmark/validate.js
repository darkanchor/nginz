/**
 * Semantic validation for upstream-balancer benchmark scenarios.
 *
 * Confirms each scenario endpoint returns the expected HTTP status and body.
 */
export async function validateScenario(baseUrl, scenario) {
  const url = `${baseUrl}${scenario.path}`;
  const init = { method: scenario.method || "GET" };
  if (scenario.headers && Object.keys(scenario.headers).length > 0) {
    init.headers = scenario.headers;
  }

  let res;
  try {
    res = await fetch(url, init);
  } catch (err) {
    return { ok: false, error: `fetch failed: ${err.message}`, scenario: scenario.name };
  }

  const expectedStatus = scenario.expectedStatus ?? 200;
  if (res.status !== expectedStatus) {
    return { ok: false, error: `HTTP ${res.status} (expected ${expectedStatus})`, scenario: scenario.name };
  }

  // For proxy-passed scenarios, confirm JSON body from mock with upstream marker
  if (scenario.name === "sticky-route" || scenario.name === "direct-route") {
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

    if (body.upstream !== "ok") {
      return { ok: false, error: `unexpected upstream value: ${JSON.stringify(body)}`, scenario: scenario.name };
    }
  }

  // For without-balancer, confirm "healthy" body
  if (scenario.name === "without-balancer") {
    const body = await res.text();
    if (body.trim() !== "healthy") {
      return { ok: false, error: `unexpected body: "${body.trim()}"`, scenario: scenario.name };
    }
  }

  return { ok: true, scenario: scenario.name };
}
