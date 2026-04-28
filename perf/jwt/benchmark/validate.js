/**
 * Semantic validation for JWT benchmark scenarios.
 *
 * Confirms each scenario endpoint returns the expected HTTP status and
 * that valid scenarios return the expected body ("OK").
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

  // For 200 responses, confirm body is "OK"
  if (expectedStatus === 200) {
    const body = await res.text();
    if (body.trim() !== "OK") {
      return { ok: false, error: `unexpected body: "${body.trim()}"`, scenario: scenario.name };
    }
  }

  // For valid-claims, confirm X-Jwt-Sub header is present
  if (scenario.name === "valid-claims") {
    const subHeader = res.headers.get("x-jwt-sub");
    if (subHeader !== "claim-user") {
      return { ok: false, error: `missing or wrong X-Jwt-Sub header: "${subHeader}"`, scenario: scenario.name };
    }
  }

  return { ok: true, scenario: scenario.name };
}
