export const SCENARIOS = [
  {
    name: "sticky-route",
    description: "GET with sticky cookie + header → 200, proxied to mock backend via balancer upstream",
    path: "/bench/balancer",
    method: "GET",
    headers: { Cookie: "route=stable-a", "X-Sticky-Key": "beta-client" },
    expectedStatus: 200,
  },
  {
    name: "direct-route",
    description: "GET with no sticky headers → 200, default upstream selection",
    path: "/bench/direct",
    method: "GET",
    headers: {},
    expectedStatus: 200,
  },
  {
    name: "without-balancer",
    description: "GET on a non-balancer location → 200 echozn (no upstream)",
    path: "/",
    method: "GET",
    headers: {},
    expectedStatus: 200,
  },
];

export function getScenario(name) {
  return SCENARIOS.find((s) => s.name === name) ?? null;
}
