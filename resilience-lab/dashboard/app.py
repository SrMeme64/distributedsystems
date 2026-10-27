"""Panel para iniciar las herramientas del laboratorio y consultar sus resultados."""
import csv
import json
import os
import re
import subprocess
import threading
import time
import uuid
from urllib.parse import urlparse

from flask import Flask, abort, jsonify, request, send_from_directory

RESULTS = "/results"
DEFAULT_TARGET = os.environ.get("DEFAULT_TARGET", "http://presentation-entry").rstrip("/")
app = Flask(__name__, static_folder="static", static_url_path="")
procs, lock = {}, threading.Lock()

F = lambda key, label, default, kind="text", **kw: {"key": key, "label": label, "default": default, "type": kind, **kw}  # noqa: E731

TOOLS = {
    "ab": {
        "title": "ApacheBench (ab)", "container": "lab-ab", "kind": "performance",
        "description": "Envía un número fijo de solicitudes a una URL para medir la tasa de solicitudes y la latencia.",
        "runbook": ["Inicia el stack principal y abre este panel.",
                    "Ejecuta la prueba rápida para confirmar que el destino responde sin solicitudes fallidas.",
                    "Ejecuta Carga y luego Estrés; compara solicitudes/s y p95/p99 entre ejecuciones.",
                    "Las solicitudes fallidas o respuestas distintas de 2xx pueden indicar saturación: revisa HAProxy y Nagios."],
        "fields": [F("TARGET_URL", "URL objetivo", DEFAULT_TARGET + "/"),
                   F("REQUESTS", "Solicitudes totales", 1000, "number", min=1, max=1000000),
                   F("CONCURRENCY", "Concurrencia", 20, "number", min=1, max=2000),
                   F("TIMEOUT", "Tiempo límite (s)", 30, "number", min=1, max=600),
                   F("KEEPALIVE", "Mantener conexión HTTP", False, "bool")],
        "presets": {"Rápida": {"REQUESTS": 100, "CONCURRENCY": 5}, "Carga": {"REQUESTS": 5000, "CONCURRENCY": 50},
                    "Estrés": {"REQUESTS": 20000, "CONCURRENCY": 200}},
    },
    "siege": {
        "title": "Siege", "container": "lab-siege", "kind": "performance",
        "description": "Genera carga durante un tiempo definido sobre varias URL con usuarios simulados.",
        "runbook": ["Introduce una URL por línea (páginas web y llamadas a /api/).",
                    "Ejecuta Rápida y luego Carga; activa el modo de benchmark para máxima presión o desactívalo para añadir tiempo de espera.",
                    "Revisa la disponibilidad (objetivo >= 99%), el tiempo de respuesta y la transacción más larga.",
                    "Ejecuta en paralelo con Chaos Monkey para observar el comportamiento durante fallos."],
        "fields": [F("URLS", "URL (una por línea)", f"{DEFAULT_TARGET}/\n{DEFAULT_TARGET}/api/health\n{DEFAULT_TARGET}/api/products/cheapest", "textarea"),
                   F("CONCURRENCY", "Usuarios concurrentes", 20, "number", min=1, max=1000),
                   F("DURATION", "Duración (s)", 30, "number", min=1, max=3600),
                   F("BENCHMARK", "Modo benchmark (sin demora)", True, "bool"),
                   F("DELAY", "Demora aleatoria máxima (s)", 1, "number", min=0, max=60)],
        "presets": {"Rápida": {"CONCURRENCY": 5, "DURATION": 10}, "Carga": {"CONCURRENCY": 50, "DURATION": 60},
                    "Estrés": {"CONCURRENCY": 200, "DURATION": 60}},
    },
    "jmeter": {
        "title": "Apache JMeter", "container": "lab-jmeter", "kind": "performance",
        "description": "Escenario con grupo de hilos y rampa de carga; genera un informe HTML completo.",
        "runbook": ["Configura la URL base y las rutas de solicitud, una por línea.",
                    "Elige los hilos, la rampa y la duración; comienza con Rápida y continúa con Carga.",
                    "Revisa aquí el porcentaje de errores, los percentiles y el rendimiento en solicitudes por segundo; abre el informe HTML para ver las gráficas.",
                    "Usa tiempo de espera para simular usuarios reales; establece 0 para medir capacidad máxima."],
        "fields": [F("BASE_URL", "URL base", DEFAULT_TARGET),
                   F("PATHS", "Rutas (una por línea)", "/\n/api/health\n/api/products/cheapest", "textarea"),
                   F("THREADS", "Hilos (usuarios)", 20, "number", min=1, max=1000),
                   F("RAMPUP", "Rampa de carga (s)", 5, "number", min=0, max=600),
                   F("DURATION", "Duración (s)", 30, "number", min=1, max=3600),
                   F("THINK_MS", "Tiempo de espera (ms)", 0, "number", min=0, max=60000)],
        "presets": {"Rápida": {"THREADS": 5, "DURATION": 15}, "Carga": {"THREADS": 50, "RAMPUP": 10, "DURATION": 60},
                    "Estrés": {"THREADS": 200, "RAMPUP": 30, "DURATION": 90}},
    },
    "chaosmonkey": {
        "title": "Chaos Monkey", "container": "lab-chaosmonkey", "kind": "resilience",
        "description": "Detiene, mata o pausa contenedores del proyecto al azar y mide la disponibilidad observada por el usuario.",
        "runbook": ["Comienza con la simulación para revisar qué contenedores serían afectados.",
                    "Elige un grupo: presentation-lb comprueba el failover VRRP; web/app, la redundancia del pool; galera/proxysql, la capa de datos; mongodb, el replica set; redis-data/redis-sentinel, el failover de caché y el quórum.",
                    "Opcionalmente, inicia Siege/JMeter en paralelo para generar carga durante la inyección de fallas.",
                    "Se espera una disponibilidad cercana al 100% para grupos redundantes. Una falla de MongoDB o Redis puede conservar HTTP 200 y marcar la respuesta como degradada. Revisa /api/health y X-Request-Trace, no solo el código HTTP.",
                    "Los objetivos se restauran automáticamente al terminar o detener la prueba."],
        "fields": [F("GROUP", "Grupo objetivo", "web", "select",
                     options=["web", "app", "presentation-lb", "application-lb", "galera", "proxysql", "mongodb", "redis", "redis-data", "redis-sentinel", "any"],
                     option_labels={"web": "Nodos web", "app": "Nodos de aplicación", "presentation-lb": "Balanceadores de presentación",
                                    "application-lb": "Balanceadores de aplicación", "galera": "Clúster Galera", "proxysql": "ProxySQL",
                                    "mongodb": "Replica set MongoDB", "redis": "Redis", "redis-data": "Nodos de datos Redis",
                                    "redis-sentinel": "Centinelas Redis", "any": "Todos los grupos"}),
                   F("TARGETS", "Servicios concretos (separados por coma; reemplaza el grupo)", "", "text", required=False),
                   F("ACTION", "Tipo de falla", "stop", "select", options=["stop", "kill", "pause"],
                     option_labels={"stop": "Detener", "kill": "Terminar", "pause": "Pausar"}),
                   F("INTERVAL", "Segundos entre fallas", 20, "number", min=1, max=3600),
                   F("DOWNTIME", "Segundos que dura la falla", 15, "number", min=1, max=3600),
                   F("DURATION", "Duración total (s)", 90, "number", min=5, max=7200),
                   F("MAX_CONCURRENT", "Máximo de víctimas simultáneas", 1, "number", min=1, max=5),
                   F("PROBE_URL", "URL para comprobar disponibilidad", DEFAULT_TARGET + "/api/health"),
                   F("DRY_RUN", "Simulación (no afecta contenedores)", False, "bool")],
        "presets": {"Suave": {"INTERVAL": 30, "DOWNTIME": 15, "DURATION": 90},
                    "Intenso": {"INTERVAL": 10, "DOWNTIME": 20, "DURATION": 120, "MAX_CONCURRENT": 2},
                    "Failover de balanceador": {"GROUP": "presentation-lb", "INTERVAL": 30, "DOWNTIME": 20, "DURATION": 90},
                    "Failover de MongoDB": {"GROUP": "mongodb", "INTERVAL": 30, "DOWNTIME": 20, "DURATION": 90},
                    "Failover de Redis": {"GROUP": "redis-data", "INTERVAL": 30, "DOWNTIME": 20, "DURATION": 90}},
    },
}


def clean_params(tool, raw):
    params = {}
    for f in TOOLS[tool]["fields"]:
        v = raw.get(f["key"], f["default"])
        if f["type"] == "number":
            try:
                v = float(v)
            except (TypeError, ValueError):
                raise ValueError(f"{f['label']} debe ser un número")
            if not f["min"] <= v <= f["max"]:
                raise ValueError(f"{f['label']} debe estar entre {f['min']} y {f['max']}")
            v = str(int(v)) if v == int(v) else str(v)
        elif f["type"] == "bool":
            v = "true" if v in (True, "true", "on", 1) else "false"
        elif f["type"] == "select":
            if v not in f["options"]:
                raise ValueError(f"{f['label']} no es válido")
        else:
            v = str(v).strip()
            if not v and f.get("required", True):
                raise ValueError(f"{f['label']} es obligatorio")
            if f["key"] in ("TARGET_URL", "PROBE_URL", "BASE_URL") and not re.match(r"^https?://[^\s]+$", v):
                raise ValueError(f"{f['label']} debe ser una URL http(s)")
            if f["key"] == "TARGETS" and v and not re.match(r"^[\w.,\- ]+$", v):
                raise ValueError("Los servicios especificados contienen caracteres no válidos")
            if f["key"] in ("URLS",) and any(not re.match(r"^https?://\S+$", u.strip()) for u in v.splitlines() if u.strip()):
                raise ValueError("Cada URL debe comenzar con http:// o https://")
            if f["key"] == "PATHS" and any(not u.strip().startswith("/") for u in v.splitlines() if u.strip()):
                raise ValueError("Cada ruta debe comenzar con /")
        params[f["key"]] = v
    if tool == "jmeter":
        u = urlparse(params.pop("BASE_URL"))
        params["PROTOCOL"] = u.scheme
        params["HOST"] = u.hostname
        params["PORT"] = str(u.port or (443 if u.scheme == "https" else 80))
    return params


def run_dir(run_id):
    return os.path.join(RESULTS, run_id)


def read_meta(run_id):
    try:
        with open(os.path.join(run_dir(run_id), "meta.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_meta(meta):
    path = os.path.join(run_dir(meta["id"]), "meta.json")
    with open(path + ".tmp", "w") as f:
        json.dump(meta, f)
    os.replace(path + ".tmp", path)


def execute(meta, params):
    tool = TOOLS[meta["tool"]]
    out = run_dir(meta["id"])
    cmd = ["docker", "exec"]
    for k, v in params.items():
        cmd += ["-e", f"{k}={v}"]
    cmd += [tool["container"], f"/runbook/run.sh", out]
    with open(os.path.join(out, "console.log"), "w") as log:
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
        with lock:
            procs[meta["id"]] = proc
        code = proc.wait()
    with lock:
        procs.pop(meta["id"], None)
    meta = read_meta(meta["id"])
    meta["finished"] = time.time()
    if meta["status"] == "stopping":
        meta["status"] = "stopped"
    else:
        meta["status"] = "finished" if code == 0 else "failed"
    meta["exit_code"] = code
    try:
        meta["summary"] = build_summary(meta)
    except Exception as e:  # noqa: BLE001 - never lose a run because of a parser bug
        meta["summary"] = {"metrics": {}, "error": f"could not parse results: {e}"}
    write_meta(meta)


# ---- result parsers -------------------------------------------------------

def num(s):
    return float(s.replace(",", ""))


def parse_ab(text, out):
    m = {}
    patterns = {
        "Solicitudes/s": r"Requests per second:\s+([\d.]+)",
        "Latencia media ms": r"Time per request:\s+([\d.]+) \[ms\] \(mean\)\n",
        "Solicitudes completadas": r"Complete requests:\s+(\d+)",
        "Solicitudes fallidas": r"Failed requests:\s+(\d+)",
        "Respuestas distintas de 2xx": r"Non-2xx responses:\s+(\d+)",
        "Transferencia KB/s": r"Transfer rate:\s+([\d.]+)",
        "Duración total s": r"Time taken for tests:\s+([\d.]+)",
    }
    for label, pat in patterns.items():
        r = re.search(pat, text)
        m[label] = num(r.group(1)) if r else (0 if label == "Respuestas distintas de 2xx" else None)
    pct = {f"p{p}": num(v) for p, v in re.findall(r"^\s+(\d+)%\s+(\d+)", text, re.M)}
    return {"metrics": m, "percentiles": pct, "unit": "ms"}


def parse_siege(text, out):
    labels = {"Transactions": "Transacciones", "Availability": "Disponibilidad %",
              "Elapsed time": "Tiempo transcurrido s", "Data transferred": "Datos transferidos MB",
              "Response time": "Tiempo medio de respuesta s", "Transaction rate": "Transacciones/s",
              "Throughput": "Caudal MB/s", "Concurrency": "Concurrencia media",
              "Successful transactions": "Transacciones exitosas", "Failed transactions": "Transacciones fallidas",
              "Longest transaction": "Transacción más larga s", "Shortest transaction": "Transacción más corta s"}
    m = {}
    for key, val in re.findall(r"^([A-Za-z ]+):\s+([\d.,]+)", text, re.M):
        if key.strip() in labels:
            m[labels[key.strip()]] = num(val)
    return {"metrics": m}


def parse_jmeter(text, out):
    path = os.path.join(out, "results.jtl")
    rows = list(csv.DictReader(open(path))) if os.path.exists(path) else []
    if not rows:
        return {"metrics": {}, "error": "JMeter no produjo muestras"}
    el = sorted(int(r["elapsed"]) for r in rows)
    ts = [int(r["timeStamp"]) for r in rows]
    span = max((max(ts) + int(rows[ts.index(max(ts))]["elapsed"]) - min(ts)) / 1000, 0.001)
    errors = sum(1 for r in rows if r["success"] != "true")
    pick = lambda p: el[min(len(el) - 1, int(len(el) * p / 100))]  # noqa: E731
    per = {}
    for r in rows:
        s = per.setdefault(r["label"], {"n": 0, "err": 0, "sum": 0})
        s["n"] += 1
        s["err"] += r["success"] != "true"
        s["sum"] += int(r["elapsed"])
    return {
        "metrics": {"Muestras": len(rows), "Errores": errors, "Errores %": round(100 * errors / len(rows), 2),
                    "Throughput req/s": round(len(rows) / span, 2),
                    "Media ms": round(sum(el) / len(el), 1), "Mínimo ms": el[0], "Máximo ms": el[-1]},
        "percentiles": {"p50": pick(50), "p90": pick(90), "p95": pick(95), "p99": pick(99)},
        "unit": "ms",
        "table": [{"label": k, "samples": v["n"], "errors": v["err"], "avg_ms": round(v["sum"] / v["n"], 1)}
                  for k, v in per.items()],
        "report": os.path.isfile(os.path.join(out, "report", "index.html")),
    }


def build_summary(meta):
    out = run_dir(meta["id"])
    if meta["tool"] == "chaosmonkey":
        p = os.path.join(out, "summary.json")
        if os.path.exists(p):
            return json.load(open(p))
        return {"metrics": {}, "error": "No se generó un resumen; consulta la consola."}
    text = open(os.path.join(out, "console.log"), errors="replace").read()
    return {"ab": parse_ab, "siege": parse_siege, "jmeter": parse_jmeter}[meta["tool"]](text, out)


# ---- API ------------------------------------------------------------------

@app.get("/api/tools")
def api_tools():
    return jsonify(TOOLS)


@app.post("/api/runs")
def api_start():
    body = request.get_json(force=True, silent=True) or {}
    tool = body.get("tool")
    if tool not in TOOLS:
        return jsonify(error="Herramienta desconocida"), 400
    try:
        params = clean_params(tool, body.get("params", {}))
    except ValueError as e:
        return jsonify(error=str(e)), 400
    run_id = time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:4]
    os.makedirs(run_dir(run_id))
    meta = {"id": run_id, "tool": tool, "status": "running", "started": time.time(),
            "params": params if tool != "jmeter" else {**params}, "summary": None}
    write_meta(meta)
    threading.Thread(target=execute, args=(meta, params), daemon=True).start()
    return jsonify(meta), 202


@app.get("/api/runs")
def api_runs():
    runs = []
    for name in sorted(os.listdir(RESULTS), reverse=True):
        meta = read_meta(name)
        if meta:
            with lock:
                active = name in procs
            if meta["status"] in ("running", "stopping") and not active:
                meta["status"] = "interrupted"
            runs.append({k: meta.get(k) for k in ("id", "tool", "status", "started", "finished", "summary")})
    return jsonify(runs[:100])


@app.get("/api/runs/<run_id>")
def api_run(run_id):
    meta = read_meta(run_id) if re.fullmatch(r"[\w-]+", run_id) else None
    if not meta:
        abort(404)
    with lock:
        active = run_id in procs
    if meta["status"] in ("running", "stopping") and not active:
        meta["status"] = "interrupted"
    try:
        with open(os.path.join(run_dir(run_id), "console.log"), errors="replace") as f:
            meta["console"] = f.read()[-20000:]
    except OSError:
        meta["console"] = ""
    meta["files"] = sorted(f for f in os.listdir(run_dir(run_id)) if os.path.isfile(os.path.join(run_dir(run_id), f)))
    return jsonify(meta)


@app.post("/api/runs/<run_id>/stop")
def api_stop(run_id):
    meta = read_meta(run_id) if re.fullmatch(r"[\w-]+", run_id) else None
    with lock:
        active = run_id in procs
    if not meta or not active:
        return jsonify(error="La ejecución no está activa"), 404
    meta["status"] = "stopping"
    write_meta(meta)
    container = TOOLS[meta["tool"]]["container"]
    script = f'p=$(cat {run_dir(run_id)}/pid); pkill -TERM -P "$p"; kill -TERM "$p"'
    subprocess.run(["docker", "exec", container, "sh", "-c", script], capture_output=True)
    return jsonify(meta)


@app.get("/files/<run_id>/<path:name>")
def files(run_id, name):
    if not re.fullmatch(r"[\w-]+", run_id):
        abort(404)
    resp = send_from_directory(run_dir(run_id), name)
    if request.args.get("download"):
        resp.headers["Content-Disposition"] = f'attachment; filename="{run_id}-{os.path.basename(name)}"'
    return resp


@app.get("/")
def index():
    return app.send_static_file("index.html")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8090, threaded=True)
