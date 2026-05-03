export const SCENARIOS = [
  {
    name: "placeholder-501",
    description: "GET on scaffold endpoint → 501 + JSON placeholder body",
    path: "/bench/dynamic-upstreams",
    method: "GET",
    expectedStatus: 501,
  },
  {
    name: "placeholder-head",
    description: "HEAD on scaffold endpoint → 501, empty body",
    path: "/bench/dynamic-upstreams",
    method: "HEAD",
    expectedStatus: 501,
  },
  {
    name: "healthy-route",
    description: "GET on neighboring healthy route → 200 'ok'",
    path: "/",
    method: "GET",
    expectedStatus: 200,
  },
];

export function getScenario(name) {
  return SCENARIOS.find((s) => s.name === name) ?? null;
}
