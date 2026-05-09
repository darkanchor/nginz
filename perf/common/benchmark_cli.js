const VALID_WORKER_EVENTS_MODES = ["off", "per_target", "summary"];

export function parseBenchmarkArgs(argv) {
  const options = {
    scenario: null,
    requests: 200,
    warmup: 20,
    concurrency: [1, 8, 32],
    service: "both",
    profile: "snapshot",
    artifactTag: "",
    keepRuntime: false,
    workerEventsMode: "per_target",
    help: false,
  };

  for (const arg of argv) {
    if (arg === "--help" || arg === "-h") {
      options.help = true;
      continue;
    }
    if (arg === "--keep-runtime") {
      options.keepRuntime = true;
      continue;
    }
    const [key, value] = arg.split("=", 2);
    if (!value) continue;
    if (key === "--scenario") options.scenario = value;
    if (key === "--requests") options.requests = Number(value);
    if (key === "--warmup") options.warmup = Number(value);
    if (key === "--service") options.service = value;
    if (key === "--profile") options.profile = value;
    if (key === "--artifact-tag") options.artifactTag = value;
    if (key === "--concurrency") {
      options.concurrency = value.split(",").map((part) => Number(part.trim())).filter((part) => part > 0);
    }
    if (key === "--worker-events-mode") {
      if (!VALID_WORKER_EVENTS_MODES.includes(value)) {
        throw new Error(`--worker-events-mode must be one of: ${VALID_WORKER_EVENTS_MODES.join(", ")}`);
      }
      options.workerEventsMode = value;
    }
  }

  return options;
}

export function printBenchmarkHelp(scriptPath) {
  console.log(`Usage: bun ${scriptPath} [options]\n\nOptions:\n  --help                 Show this help\n  --scenario=<name>      Run a single scenario\n  --requests=<n>         Timed requests per scenario/concurrency/service (default: 200)\n  --warmup=<n>           Warmup requests per scenario/service (default: 20)\n  --concurrency=a,b,c    Concurrency list (default: 1,8,32)\n  --service=<both|pgrest|postgrest>  Service selection (default: both)\n  --profile=<none|snapshot|perf-stat>  Profiling mode (default: snapshot)\n  --artifact-tag=<slug>  Optional tag appended to the run directory name\n  --keep-runtime         Keep benchmark runtime artifacts\n  --worker-events-mode=<off|per_target|summary>  cache_purge worker-events mode (default: per_target)`);
}
