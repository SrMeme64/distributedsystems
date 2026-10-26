# Resilience, HA, Failover and Performance Test Plan

Complete test set for the `distributed-three-tier` project, plus commonly used tools.
The lab in this folder already covers ab, Siege, JMeter and container-level Chaos Monkey faults.

## 1. Baseline and functional checks (before any fault)

- Every layer is healthy: HAProxy backends all UP, `/api/health` returns OK, Galera `wsrep_cluster_size=3`, `rs0` has one PRIMARY and two SECONDARY members, and Sentinel reports `mymaster` with two replicas.
- ProxySQL classifies the Galera nodes: one ONLINE writer in hostgroup 10 and readers in hostgroup 30.
- Round-robin: the `X-Web-Node` and `X-Presentation-LB` headers rotate across web1-3.
- Data consistency: a write on one Galera node is readable on the others; cache hits and misses behave correctly.
- `GET /api/health` returns 200 `degraded` (not 503) when only MongoDB or Redis is down.

## 2. Performance tests

| Test | Goal | Lab tool |
|---|---|---|
| Smoke | Confirm the path works with 1-5 users | ab, JMeter |
| Load | Expected traffic held for 10-30 minutes | JMeter, Siege |
| Stress | Ramp up until errors or latency climb; find the first bottleneck | ab, JMeter |
| Spike | Jump from 5 to 300 users within seconds, then recover | JMeter |
| Soak | Moderate load for hours to catch leaks and connection exhaustion | JMeter |
| Cache effect | Compare latency with and without Redis (`/cache/clear`) | JMeter |
| Capacity per layer | Test web, app and DB directly, bypassing upper layers, to locate the bottleneck | ab |

Track p50/p95/p99 latency, throughput, error rate and CPU/memory per container (`docker stats` or cAdvisor).
Use SLO-style targets, e.g. p95 < 200 ms and availability >= 99.9%.

## 3. HA and failover tests

Run each under constant load; record outage time and failed requests.

| Component | Fault | Expected result |
|---|---|---|
| Presentation LB master | stop, kill, pause | VIP moves to the backup within about 3-4 s |
| Presentation LB master | HAProxy hangs but container stays up | Keepalived check script fails, priority drops by 20, backup takes over |
| Presentation LB master | recovery | Failback without flapping |
| Application LB master | same three faults | Same, on `172.31.0.250` |
| Both LBs of one tier | stop both | Total outage, recovery on restart (negative test) |
| 1 of 3 web/app nodes | stop | HAProxy health check drops it; zero or near-zero errors |
| 2 of 3 web/app nodes | stop | Reduced capacity but still serving |
| Galera writer (hostgroup 10) | stop the current writer | ProxySQL promotes another node; reads and writes keep working |
| Galera node | stop galera2 or galera3 | Cluster keeps quorum; ProxySQL reclassifies the node |
| Galera node | stop galera1 | **No longer a single point**: ProxySQL promotes another writer |
| ProxySQL | stop | Total database outage for the API (negative test); restart restores service |
| MongoDB primary | stop mongo1 (or the current primary) | `rs0` elects a new primary; reviews keep working (200/201) |
| MongoDB secondary | stop mongo2 or mongo3 | Replica set keeps a primary and a secondary; no user impact |
| Redis master | stop the current master | Sentinel promotes a replica; catalog keeps working, possibly from MariaDB during the transition |
| Redis all data nodes | stop master and replicas | `/api/health` 200 `degraded`; catalog 200 from MariaDB; `/cache/clear` 503 |
| Redis sentinels | stop two of three | No automatic failover while quorum is lost; the current master still serves |
| Redis | stop all six containers | Graceful degradation: slower DB-only reads, no 500s on the catalog |
| Entry proxy | stop | Total outage, accepted Docker Desktop limitation |

## 4. Chaos engineering tests

Each experiment: state a steady-state hypothesis (e.g. availability >= 99% and p95 < 500 ms), inject the fault,
compare against the hypothesis, recover, record findings.

- **Container faults:** random stop/kill/pause, several victims at once (covered by the lab).
- **Network faults:** latency, jitter, packet loss, bandwidth limits, partitions between app and DB or between Galera halves (split-brain). Not yet in the lab; use Pumba or Toxiproxy.
- **Resource faults:** CPU hog, memory pressure, disk full/slow, file-descriptor exhaustion (`stress-ng`, Pumba stress).
- **Time faults:** clock skew, which affects Keepalived and Galera.
- **Dependency faults:** DB slowness without failure, exposing missing timeouts and retry storms.
- **Compound faults:** load test plus node failure plus cache flush at the same time.
- **Recovery faults:** restart the whole stack; check startup order, cold cache and Galera re-bootstrap after losing all nodes.

## 5. Observability and alerting checks

- Nagios alerts on each fault within its check interval; count missed and false alerts.
- Logs are sufficient to reconstruct the timeline.
- Record mean time to detect, mean time to recover and error budget burn per experiment.

## Gaps the tests will likely expose

- `presentation-entry` is a single point of failure.
- ProxySQL is a single instance; stopping it takes the whole database tier out of the API.
- Compose `restart: always` restarts containers when Docker starts, but a `docker compose down` removes them: after `down`, run `Start-Stack.ps1` (or `docker compose up -d`) to recreate them.
- All containers still run on one Docker host, so host or Docker Desktop failure is a total outage.
- Sentinel uses fixed IPs in the `172.32.0.0/24` database network; changing that subnet requires updating `redis/sentinel.conf` and `redis/redis-replica.conf`.

## Results observed on 2026-10-23

| Fault | Observed result |
|---|---|
| `galera3` (writer) stopped | ProxySQL promoted `galera2`; a test write inserted 1 row; catalog stayed 200. After restart, `galera3` became writer again and the cluster returned to `size=3`, `Synced`, `Primary`. |
| `mongo1` (primary) stopped | `mongo2` was elected primary; `GET` reviews returned 200 and `POST` returned 201. After restart, `mongo1` became primary again. |
| Current Redis master stopped | Sentinel promoted another node; `/api/health` returned 200 and the catalog returned 200 with `redis (unavailable) -> mariadb`; `/cache/clear` returned 503. |
| All Redis containers stopped | `/api/health` returned 200 `degraded`; the catalog returned 200 from MariaDB. After restart, health returned to `ok` and the catalog repopulated the cache. |
| `app1` stopped | HAProxy removed the node in ~6.4 s; `/api/health` stayed 200 on `app2`/`app3` (7 of 8 probes 200 during the window). |
| `presentation-lb-master` paused | Keepalived moved the VIP `172.30.0.250` to `presentation-lb-backup` in ~7.7 s; first 200 trace on the backup at ~10.4 s; failback ~3.4 s. |
| `application-lb-master` paused | Keepalived moved the VIP `172.31.0.250` to `application-lb-backup`; first 200 trace on the backup at ~10.3 s; failback ~4.4 s. |

## Commonly used tools

| Area | Tools |
|---|---|
| HTTP load | k6 (JS scripts, CI-friendly), Locust (Python), Gatling, wrk/wrk2 (constant rate, accurate latency), vegeta, hey, bombardier, Artillery |
| Enterprise / distributed load | BlazeMeter, Tsung, NBomber, Taurus (YAML wrapper over JMeter, Gatling, etc.) |
| Chaos, containers/Docker | Pumba (kill, pause, netem, stress), Chaos Toolkit (declarative experiments), Gremlin (SaaS) |
| Chaos, Kubernetes | Chaos Mesh, LitmusChaos, Netflix Chaos Monkey / Simian Army (cloud, Spinnaker) |
| Chaos, cloud | AWS Fault Injection Service, Azure Chaos Studio |
| Network faults | Toxiproxy, tc/netem, Comcast, iptables |
| Host/resource stress | stress-ng, fio, iperf3 |
| Database | sysbench, HammerDB, mysqlslap, pgbench, YCSB, mongoperf, redis-benchmark |
| Distributed correctness | Jepsen (for databases like Galera and MongoDB) |
| Observability | Prometheus + Grafana, cAdvisor, node_exporter, Loki, Jaeger/OpenTelemetry, HAProxy stats and exporter, mysqld_exporter, Nagios/Zabbix |
| CI gating | GitHub Actions with k6 thresholds, Taurus |
| Game days | Written runbooks and blameless postmortems |

## Suggested next steps

1. Add Prometheus and Grafana (HAProxy exporter, cAdvisor) so each experiment has graphs of its hypothesis.
2. Add Pumba or Toxiproxy to the lab for latency, loss and partition experiments.
3. Add k6 or Locust for scripted, threshold-based tests that can run in CI.
4. Automate the ProxySQL, MongoDB and Redis failover checks in a repeatable script and record detection/recovery times.
5. Exercise split-brain and network partitions between Galera halves and between the API and the data tier.
