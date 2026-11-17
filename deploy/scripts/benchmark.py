#!/usr/bin/env python3
import argparse
import concurrent.futures
import json
import math
import statistics
import time
from urllib.request import Request, urlopen


REQUESTS = 100
CONCURRENCY = 5
COLD_SAMPLES = 10
CATALOG_PATH = "/api/products/cheapest"


def request(base_url, path, method="GET"):
    req = Request(f"{base_url}{path}", method=method)
    with urlopen(req, timeout=10) as response:
        body = response.read()
        return response.status, response.headers, body


def catalog_request(base_url):
    started = time.perf_counter()
    status, headers, body = request(base_url, CATALOG_PATH)
    elapsed_ms = (time.perf_counter() - started) * 1000
    products = json.loads(body)
    if status != 200 or len(products) != 10:
        raise RuntimeError(f"Unexpected catalog response: HTTP {status}, {len(products)} products")
    return elapsed_ms, headers.get("X-Request-Trace", "").lower()


def percentile(samples, fraction):
    ordered = sorted(samples)
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def summarize(samples):
    return {
        "samples": len(samples),
        "p50_ms": round(percentile(samples, 0.50), 2),
        "p95_ms": round(percentile(samples, 0.95), 2),
        "p99_ms": round(percentile(samples, 0.99), 2),
        "max_ms": round(max(samples), 2),
    }


def main():
    parser = argparse.ArgumentParser(
        description="Measure local cold-cache and hot-cache catalog response times."
    )
    parser.add_argument("--url", default="http://127.0.0.1:8080")
    args = parser.parse_args()
    base_url = args.url.rstrip("/")

    cold_samples = []
    for _ in range(COLD_SAMPLES):
        status, _, _ = request(base_url, "/api/cache/clear", method="POST")
        if status != 200:
            raise RuntimeError(f"Cache clear failed with HTTP {status}")
        elapsed_ms, trace = catalog_request(base_url)
        if "redis (cache miss)" not in trace:
            raise RuntimeError(f"Expected a cold-cache request, got trace: {trace}")
        cold_samples.append(elapsed_ms)

    _, hot_trace = catalog_request(base_url)
    if "cache hit" not in hot_trace:
        raise RuntimeError(f"Expected a warm-cache request, got trace: {hot_trace}")

    started = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=CONCURRENCY) as executor:
        hot_results = list(executor.map(lambda _: catalog_request(base_url), range(REQUESTS)))
    elapsed_seconds = time.perf_counter() - started

    if any("cache hit" not in trace for _, trace in hot_results):
        raise RuntimeError("At least one concurrent catalog request missed the warm cache")

    hot_latencies = [elapsed_ms for elapsed_ms, _ in hot_results]
    print(
        json.dumps(
            {
                "target": base_url,
                "cold_cache": summarize(cold_samples),
                "hot_cache": {
                    **summarize(hot_latencies),
                    "requests_per_second": round(REQUESTS / elapsed_seconds, 2),
                    "concurrency": CONCURRENCY,
                    "cache_hits": len(hot_results),
                },
                "cold_cache_mean_ms": round(statistics.mean(cold_samples), 2),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
