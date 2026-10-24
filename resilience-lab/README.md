# Resilience Lab

Containerised performance and resilience tests for the main `distributed-three-tier` stack,
with a dashboard to launch each test, enter its parameters and read the results.

## Run

```sh
docker compose --env-file .env.exam up -d --build  # desde la raíz: stack principal
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
3. **Resilience**: Chaos Monkey *Dry run*, then groups `web`, `app`, `presentation-lb` (VRRP failover), `galera` (ProxySQL writer promotion).
4. **Data tier**: groups `mongodb` (replica-set election), `redis-data` (Sentinel promotion) and `redis-sentinel` (quorum loss). Check `/api/health` and the `X-Request-Trace` header, because a degraded dependency may still return HTTP 200.
5. **Combined**: start Siege or JMeter *Load*, then Chaos Monkey in parallel; availability and error % show user impact.

## Notes

- Chaos Monkey only touches containers of the compose project `TARGET_PROJECT`; it never touches
  `presentation-entry`, `nagios`, `catalog-init`, `db-bootstrap`, `mongo-init` or `mongo-keyfile-init`,
  restores victims at the end (or on Stop), and restarts the Keepalived sidecar after a load balancer
  comes back (it shares the balancer's network namespace).
- A fault in MongoDB or Redis should keep the catalog at HTTP 200 and show `degraded` in `/api/health`;
  a fault in ProxySQL or MariaDB is a real database outage and should return 503.
- Redis Sentinel monitors the fixed master IP `172.32.0.11` on the `172.32.0.0/24` database network.
  If the subnet changes, update `redis/sentinel.conf` and `redis/redis-replica.conf`.
- `galera1` uses `galera/entrypoint.sh`: with existing data and `safe_to_bootstrap=0` it joins the
  running cluster instead of refusing to start. If every Galera node is down and none has
  `safe_to_bootstrap=1`, recover the most advanced node manually with `wsrep-recover`.
- The dashboard and Chaos Monkey mount `/var/run/docker.sock`: run the lab only on a trusted local machine.
- Results: `docker compose down -v` removes the `results` volume.
