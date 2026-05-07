export const SCENARIOS = [
  {
    name: "sticky-read",
    description: "Steady proxied GET through balancer, dynamic-upstreams, and health-aware peer eligibility.",
    kind: "proxy-read",
    path: "/app/data?tag=steady-read",
    headers: {
      Cookie: "route=steady-client",
    },
  },
  {
    name: "sticky-read-with-churn",
    description: "Same proxied GET path while dynamic-upstreams keeps activating new snapshots in the background.",
    kind: "proxy-read",
    path: "/app/data?tag=steady-churn",
    headers: {
      Cookie: "route=churn-client",
    },
    withChurn: true,
  },
  {
    name: "capture-and-purge",
    description: "Capture cache tags on a proxied response, then invalidate them through cache-purge.",
    kind: "capture-and-purge",
    headers: {
      Cookie: "route=purge-client",
    },
  },
  {
    name: "capture-purge-with-churn",
    description: "Worst-case combo path: capture and exact purge on every iteration while dynamic-upstreams keeps activating snapshots in the background.",
    kind: "capture-and-purge",
    headers: {
      Cookie: "route=storm-client",
    },
    withChurn: true,
  },
];

export function getScenario(name) {
  return SCENARIOS.find((scenario) => scenario.name === name) ?? null;
}
