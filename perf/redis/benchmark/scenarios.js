export const SCENARIOS = [
  {
    name: "small-read",
    description: "GET a small string value (~50 bytes)",
    path: "/bench/small",
  },
  {
    name: "medium-read",
    description: "GET a medium string value (~1 KB)",
    path: "/bench/medium",
  },
  {
    name: "large-read",
    description: "GET a large string value (~10 KB)",
    path: "/bench/large",
  },
  {
    name: "static-read",
    description: "GET a static-key value (avoids URI key extraction)",
    path: "/bench/static",
  },
];

export function getScenario(name) {
  return SCENARIOS.find((scenario) => scenario.name === name) ?? null;
}
