#!/usr/bin/env bash
set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1 && [[ -x "$HOME/.local/bin/kubectl" ]]; then
  PATH="$HOME/.local/bin:$PATH"
  export PATH
fi

repository_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")/../.." rev-parse --show-toplevel)"
namespace="${NAMESPACE:-store}"
port="${PORT:-18080}"
temporary_directory="$(mktemp -d)"
port_forward_log="$temporary_directory/port-forward.log"
port_forward_pid=""

cleanup() {
  if [[ -n "$port_forward_pid" ]]; then
    kill "$port_forward_pid" 2>/dev/null || true
    wait "$port_forward_pid" 2>/dev/null || true
  fi
  rm -f \
    "$port_forward_log" \
    "$temporary_directory/home.html" \
    "$temporary_directory/healthz.json" \
    "$temporary_directory/readyz.json" \
    "$temporary_directory/health.json" \
    "$temporary_directory/cache-clear.json" \
    "$temporary_directory/catalog-cold.json" \
    "$temporary_directory/catalog-cold.headers" \
    "$temporary_directory/catalog-hot.json" \
    "$temporary_directory/catalog-hot.headers" \
    "$temporary_directory/reviews.json" \
    "$temporary_directory/queued-review.json" \
    "$temporary_directory/queued-review-duplicate.json" \
    "$temporary_directory/queued-reviews.json" \
    "$temporary_directory/invalid-review.json" \
    "$temporary_directory/otel.log" \
    "$temporary_directory/grafana-health.json" \
    "$temporary_directory/grafana-dashboard.json" \
    "$temporary_directory/tempo-search.json" \
    "$temporary_directory/tempo-mysql-search.json" \
    "$temporary_directory/tempo-mongodb-search.json" \
    "$temporary_directory/tempo-redis-search.json" \
    "$temporary_directory/tempo-rabbitmq-search.json" \
    "$temporary_directory/tempo-worker-search.json" \
    "$temporary_directory/prometheus-query.json"
  rmdir "$temporary_directory"
}
trap cleanup EXIT

kubectl -n "$namespace" port-forward --address 127.0.0.1 "service/web" "$port:80" \
  >"$port_forward_log" 2>&1 &
port_forward_pid=$!

for attempt in {1..15}; do
  if curl --silent --fail --max-time 2 "http://127.0.0.1:$port/healthz" >/dev/null; then
    break
  fi
  sleep 1
done

curl --silent --show-error --fail --max-time 10 \
  --output "$temporary_directory/home.html" \
  --write-out 'store HTTP %{http_code}\n' "http://127.0.0.1:$port/"
curl --silent --show-error --fail --max-time 10 \
  --output "$temporary_directory/healthz.json" \
  --write-out 'API liveness HTTP %{http_code}\n' "http://127.0.0.1:$port/api/healthz"
curl --silent --show-error --fail --max-time 10 \
  --output "$temporary_directory/readyz.json" \
  --write-out 'API readiness HTTP %{http_code}\n' "http://127.0.0.1:$port/api/readyz"
curl --silent --show-error --fail --max-time 10 \
  --output "$temporary_directory/health.json" \
  --write-out 'dependency health HTTP %{http_code}\n' "http://127.0.0.1:$port/api/health"
curl --silent --show-error --fail --max-time 10 \
  --output "$temporary_directory/cache-clear.json" \
  --write-out 'cache clear HTTP %{http_code}\n' \
  --request POST "http://127.0.0.1:$port/api/cache/clear"
curl --silent --show-error --fail --max-time 10 \
  --dump-header "$temporary_directory/catalog-cold.headers" \
  --output "$temporary_directory/catalog-cold.json" \
  --write-out 'catalog cold HTTP %{http_code}\n' \
  "http://127.0.0.1:$port/api/products/cheapest"
curl --silent --show-error --fail --max-time 10 \
  --dump-header "$temporary_directory/catalog-hot.headers" \
  --output "$temporary_directory/catalog-hot.json" \
  --write-out 'catalog hot HTTP %{http_code}\n' \
  "http://127.0.0.1:$port/api/products/cheapest"
curl --silent --show-error --fail --max-time 10 \
  --output "$temporary_directory/reviews.json" \
  --write-out 'review read HTTP %{http_code}\n' \
  "http://127.0.0.1:$port/api/products/ST-001/reviews"
invalid_review_status="$(curl --silent --show-error --max-time 10 \
  --output "$temporary_directory/invalid-review.json" \
  --write-out '%{http_code}' \
  --header 'Content-Type: application/json' \
  --data '{}' "http://127.0.0.1:$port/api/products/ST-001/reviews")"
printf 'invalid review HTTP %s\n' "$invalid_review_status"
[[ "$invalid_review_status" == "400" ]] || {
  echo "Expected invalid review response HTTP 400." >&2
  exit 1
}

review_payload='{"reviewer":"Local async smoke","rating":5,"comment":"Idempotent local queue smoke fixture"}'
for response_file in queued-review.json queued-review-duplicate.json; do
  queued_review_status="$(curl --silent --show-error --max-time 10 \
    --output "$temporary_directory/$response_file" \
    --write-out '%{http_code}' \
    --header 'Content-Type: application/json' \
    --header 'Idempotency-Key: local-async-review-smoke-v1' \
    --data "$review_payload" \
    "http://127.0.0.1:$port/api/products/ST-001/reviews")"
  printf 'queued review HTTP %s\n' "$queued_review_status"
  [[ "$queued_review_status" == "202" ]] || {
    echo "Expected queued review response HTTP 202." >&2
    exit 1
  }
done

queued_review_persisted=false
for attempt in {1..30}; do
  curl --silent --show-error --fail --max-time 10 \
    --output "$temporary_directory/queued-reviews.json" \
    "http://127.0.0.1:$port/api/products/ST-001/reviews"
  if python3 - "$temporary_directory/queued-reviews.json" <<'PY'
import json
import sys
from pathlib import Path

reviews = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["reviews"]
matches = [
    review
    for review in reviews
    if review["comment"] == "Idempotent local queue smoke fixture"
]
if len(matches) != 1:
    raise SystemExit(1)
PY
  then
    queued_review_persisted=true
    break
  fi
  sleep 1
done
[[ "$queued_review_persisted" == true ]] || {
  echo "Queued review was not persisted exactly once by the worker." >&2
  exit 1
}

python3 - "$temporary_directory" <<'PY'
import json
import sys
from pathlib import Path

directory = Path(sys.argv[1])
read = lambda name: (directory / name).read_text(encoding="utf-8")
healthz = json.loads(read("healthz.json"))
readyz = json.loads(read("readyz.json"))
health = json.loads(read("health.json"))
products = json.loads(read("catalog-cold.json"))
hot_products = json.loads(read("catalog-hot.json"))
reviews = json.loads(read("reviews.json"))
invalid_review = json.loads(read("invalid-review.json"))
queued_review = json.loads(read("queued-review.json"))
duplicate_queued_review = json.loads(read("queued-review-duplicate.json"))

def trace(filename):
    for line in read(filename).splitlines():
        if line.lower().startswith("x-request-trace:"):
            return line.split(":", 1)[1].strip().lower()
    return ""

assert healthz["status"] == "ok", "liveness endpoint failed"
assert readyz["status"] == "ok", "readiness endpoint failed"
assert health["status"] == "ok" and set(health["dependencies"].values()) == {"ok"}, "dependency health failed"
assert len(products) == 10 and products[0]["sku"] == "ST-001", "catalog seed or ordering failed"
assert hot_products == products, "cached catalog differs from database result"
assert "redis (cache miss)" in trace("catalog-cold.headers"), "cold request did not reach MariaDB"
assert "cache hit" in trace("catalog-hot.headers"), "hot request did not hit Redis"
assert reviews["sku"] == "ST-001" and reviews["reviews"], "MongoDB review seed is missing"
assert "error" in invalid_review, "invalid review request was not rejected"
assert queued_review["status"] == "accepted", "review was not accepted by RabbitMQ"
assert duplicate_queued_review["status"] == "accepted", "duplicate review was not accepted idempotently"
assert "Ten cheapest products" in read("home.html"), "storefront page did not render"
print(
    "Smoke assertions passed: dependencies={}, products={}, seeded_reviews={}, async_review=once".format(
        len(health["dependencies"]), len(products), len(reviews["reviews"])
    )
)
PY

otel_trace_seen=false
for attempt in {1..15}; do
  if kubectl -n "$namespace" logs deployment/otel-collector --since=5m --tail=1000 \
    >"$temporary_directory/otel.log" 2>/dev/null &&
    grep -q "store-catalog-api" "$temporary_directory/otel.log"; then
    otel_trace_seen=true
    break
  fi
  sleep 1
done
[[ "$otel_trace_seen" == true ]] || {
  echo "OpenTelemetry traces from the API were not received by the collector." >&2
  exit 1
}
echo "OpenTelemetry traces received by the local collector"
curl --silent --show-error --fail --max-time 10 \
  --output "$temporary_directory/grafana-health.json" \
  --write-out 'Grafana health HTTP %{http_code}\n' \
  "http://127.0.0.1:3000/api/health"
python3 - "$temporary_directory/grafana-dashboard.json" \
  "$repository_root/deploy/overlays/local/secrets/lgtm.env" <<'PY'
import base64
import json
import sys
from pathlib import Path
from urllib.request import Request, urlopen

dashboard_path = Path(sys.argv[1])
secrets_path = Path(sys.argv[2])
secrets = dict(
    line.split("=", 1)
    for line in secrets_path.read_text(encoding="utf-8").splitlines()
    if "=" in line and not line.lstrip().startswith("#")
)
password = secrets.get("GF_SECURITY_ADMIN_PASSWORD")
assert password, "Grafana admin password is missing from the local secrets file"
authorization = base64.b64encode(f"admin:{password}".encode()).decode()
request = Request(
    "http://127.0.0.1:3000/api/dashboards/uid/distributed-store-api",
    headers={"Authorization": f"Basic {authorization}"},
)
with urlopen(request, timeout=10) as response:
    dashboard_path.write_bytes(response.read())

dashboard = json.loads(dashboard_path.read_text(encoding="utf-8"))["dashboard"]
assert dashboard["title"] == "Distributed Store API", "API dashboard was not provisioned"
queries = [
    target["expr"]
    for panel in dashboard["panels"]
    for target in panel.get("targets", [])
]
assert any("http_server_request_duration_seconds_count" in query for query in queries), \
    "API request-rate panel is missing"
assert any("histogram_quantile(0.95" in query for query in queries), \
    "API p95 latency panel is missing"
assert any("catalog_cache_requests_total" in query for query in queries), \
    "catalog cache hit-rate panel is missing"
PY

tempo_trace_seen=false
for attempt in {1..30}; do
  if curl --silent --fail --max-time 5 \
    --output "$temporary_directory/tempo-search.json" \
    'http://127.0.0.1:3200/api/search?tags=service.name%3Dstore-catalog-api&limit=5' &&
    python3 - "$temporary_directory/tempo-search.json" <<'PY'
import json
import sys
from pathlib import Path

if not json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")).get("traces"):
    raise SystemExit(1)
PY
  then
    tempo_trace_seen=true
    break
  fi
  sleep 1
done
[[ "$tempo_trace_seen" == true ]] || {
  echo "API traces were not found in Tempo." >&2
  exit 1
}
echo "Tempo contains API traces"

for database_system in mysql mongodb redis; do
  database_trace_seen=false
  for attempt in {1..30}; do
    if curl --silent --fail --max-time 5 --get \
      --data-urlencode "tags=db.system.name=$database_system" \
      --data-urlencode 'limit=5' \
      --output "$temporary_directory/tempo-$database_system-search.json" \
      "http://127.0.0.1:3200/api/search" &&
      python3 - "$temporary_directory/tempo-$database_system-search.json" <<'PY'
import json
import sys
from pathlib import Path

if not json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")).get("traces"):
    raise SystemExit(1)
PY
    then
      database_trace_seen=true
      break
    fi
    sleep 1
  done
  [[ "$database_trace_seen" == true ]] || {
    echo "Tempo did not find $database_system database/cache spans." >&2
    exit 1
  }
  echo "Tempo contains $database_system spans"
done

for span_service in rabbitmq worker; do
  case "$span_service" in
    rabbitmq) tag='messaging.system=rabbitmq' ;;
    worker) tag='service.name=store-review-worker' ;;
  esac
  span_seen=false
  for attempt in {1..30}; do
    if curl --silent --fail --max-time 5 --get \
      --data-urlencode "tags=$tag" \
      --data-urlencode 'limit=5' \
      --output "$temporary_directory/tempo-$span_service-search.json" \
      "http://127.0.0.1:3200/api/search" &&
      python3 - "$temporary_directory/tempo-$span_service-search.json" <<'PY'
import json
import sys
from pathlib import Path

if not json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")).get("traces"):
    raise SystemExit(1)
PY
    then
      span_seen=true
      break
    fi
    sleep 1
  done
  [[ "$span_seen" == true ]] || {
    echo "Tempo did not find $span_service traces." >&2
    exit 1
  }
  echo "Tempo contains $span_service traces"
done

python3 - "$temporary_directory/tempo-rabbitmq-search.json" <<'PY'
import json
import sys
from pathlib import Path
from urllib.request import urlopen

search = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for trace in search.get("traces", []):
    with urlopen(f"http://127.0.0.1:3200/api/traces/{trace['traceID']}", timeout=10) as response:
        detail = json.load(response)
    services = {}
    for batch in detail.get("batches", []):
        attributes = batch.get("resource", {}).get("attributes", [])
        resource = {
            attribute.get("key"): attribute.get("value", {}).get("stringValue")
            for attribute in attributes
        }
        name = resource.get("service.name")
        scopes = batch.get("scopeSpans", batch.get("instrumentationLibrarySpans", []))
        services.setdefault(name, []).extend(
            span.get("name")
            for scope in scopes
            for span in scope.get("spans", [])
        )
    if (
        "rabbitmq publish reviews.created" in services.get("store-catalog-api", [])
        and "rabbitmq process reviews.created" in services.get("store-review-worker", [])
    ):
        print("Tempo confirms W3C context links API publish and worker consume spans")
        break
else:
    raise SystemExit("RabbitMQ producer and consumer spans did not share a trace.")
PY

http_metrics_seen=false
for attempt in {1..30}; do
  if curl --silent --fail --max-time 5 --get \
    --data-urlencode 'query=http_server_request_duration_seconds_count{service_name="store-catalog-api"}' \
    --output "$temporary_directory/prometheus-query.json" \
    "http://127.0.0.1:9090/api/v1/query" &&
    python3 - "$temporary_directory/prometheus-query.json" \
      "$temporary_directory/grafana-dashboard.json" <<'PY'
import json
import sys
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload.get("data", {}).get("result")
dashboard = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))["dashboard"]
for panel in dashboard["panels"]:
    for target in panel.get("targets", []):
        url = "http://127.0.0.1:9090/api/v1/query?" + urlencode({"query": target["expr"]})
        with urlopen(url, timeout=5) as response:
            result = json.load(response)
        if result.get("status") != "success" or not result.get("data", {}).get("result"):
            raise SystemExit(1)
PY
  then
    http_metrics_seen=true
    break
  fi
  sleep 1
done
[[ "$http_metrics_seen" == true ]] || {
  echo "API HTTP metrics were not found in Prometheus." >&2
  exit 1
}
echo "Prometheus contains API HTTP metrics and data for every dashboard panel"
