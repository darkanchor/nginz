export async function validateScenario(baseUrl, scenario) {
  const url = `${baseUrl}${scenario.path}`;
  const init = { method: scenario.method || "GET" };

  let res;
  try {
    res = await fetch(url, init);
  } catch (err) {
    return { ok: false, error: `fetch failed: ${err.message}`, scenario: scenario.name };
  }

  if (res.status !== scenario.expectedStatus) {
    return { ok: false, error: `HTTP ${res.status} (expected ${scenario.expectedStatus})`, scenario: scenario.name };
  }

  if (scenario.name === "placeholder-501") {
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

    if (body.status !== "not_implemented" || body.module !== "worker_events") {
      return { ok: false, error: `unexpected body: ${JSON.stringify(body)}`, scenario: scenario.name };
    }
  }

  if (scenario.name === "placeholder-head") {
    const text = await res.text();
    if (text !== "") {
      return { ok: false, error: `HEAD returned non-empty body: "${text}"`, scenario: scenario.name };
    }
  }

  if (scenario.name === "healthy-route") {
    const body = await res.text();
    if (body.trim() !== "ok") {
      return { ok: false, error: `unexpected body: "${body.trim()}"`, scenario: scenario.name };
    }
  }

  return { ok: true, scenario: scenario.name };
}
