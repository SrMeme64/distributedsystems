# Resilience Lab

Containerised performance and resilience tests for the main `distributed-three-tier` stack,
with a dashboard to launch each test, enter its parameters and read the results.

## Run

```sh
docker compose up -d --build            # in the repository root (main stack)
cd resilience-lab && docker compose up -d --build
open http://localhost:8090
```

The lab joins the main stack's `distributed-three-tier_edge` network and targets
`http://presentation-entry` (override with `DEFAULT_TARGET`, `TARGET_PROJECT`, `DASHBOARD_PORT` env vars).

| Tool | Container | Purpose |
|------|-----------|---------|
| ApacheBench | `lab-ab` | Fixed request count against one URL: quick baseline |
| Siege | `lab-siege` | Time-boxed multi-URL load with simulated users |
| JMeter | `lab-jmeter` | Ramp-up thread-group scenario, percentiles and HTML report |
| Chaos Monkey | `lab-chaosmonkey` | Stops/kills/pauses random containers while probing availability |

Each tool container ships a runbook script (`<tool>/run.sh`, `chaosmonkey/chaosmonkey.py`); the dashboard
runs it with `docker exec`, stores console output and artefacts in the `results` volume and parses them.
Each tool's runbook steps are also shown in the dashboard.

## Suggested runbook

1. **Baseline**: ab / JMeter *Smoke* then *Load*; note requests/s and p95.
2. **Capacity**: *Stress* presets until errors or latency climb.
3. **Resilience**: Chaos Monkey *Dry run*, then groups `web`, `app`, `presentation-lb` (VRRP failover), `galera`.
4. **Combined**: start Siege or JMeter *Load*, then Chaos Monkey in parallel; availability and error % show user impact.

## Notes

- Chaos Monkey only touches containers of the compose project `TARGET_PROJECT`; it never touches
  `presentation-entry`, `nagios` or `catalog-init`, restores victims at the end (or on Stop), and restarts the
  Keepalived sidecar after a load balancer comes back (it shares the balancer's network namespace).
- The dashboard and Chaos Monkey mount `/var/run/docker.sock`: run the lab only on a trusted local machine.
- Results: `docker compose down -v` removes the `results` volume.
