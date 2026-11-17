import { metrics, SpanKind, SpanStatusCode, trace } from "@opentelemetry/api";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { OTLPMetricExporter } from "@opentelemetry/exporter-metrics-otlp-http";
import { HttpInstrumentation } from "@opentelemetry/instrumentation-http";
import { MongoDBInstrumentation } from "@opentelemetry/instrumentation-mongodb";
import { MySQL2Instrumentation } from "@opentelemetry/instrumentation-mysql2";
import { NodeSDK } from "@opentelemetry/sdk-node";
import { PeriodicExportingMetricReader } from "@opentelemetry/sdk-metrics";

const signalEndpoint = (signal) => {
  const specific = process.env[`OTEL_EXPORTER_OTLP_${signal.toUpperCase()}_ENDPOINT`];
  if (specific) {
    return specific;
  }
  const endpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT;
  return endpoint ? `${endpoint.replace(/\/$/, "")}/v1/${signal}` : null;
};

const tracesEndpoint = signalEndpoint("traces");
const metricsEndpoint = signalEndpoint("metrics");
const sdk = tracesEndpoint || metricsEndpoint
  ? new NodeSDK({
      ...(tracesEndpoint && {
        traceExporter: new OTLPTraceExporter({ url: tracesEndpoint }),
      }),
      ...(metricsEndpoint && {
        metricReader: new PeriodicExportingMetricReader({
          exporter: new OTLPMetricExporter({ url: metricsEndpoint }),
          exportIntervalMillis: 15_000,
        }),
      }),
      instrumentations: [
        new HttpInstrumentation(),
        new MongoDBInstrumentation({ enhancedDatabaseReporting: false }),
        new MySQL2Instrumentation({ maskStatement: true }),
      ],
    })
  : null;

if (sdk) {
  await sdk.start();
  console.log("OpenTelemetry HTTP, database, and Redis telemetry enabled");
}

const tracer = trace.getTracer(process.env.OTEL_SERVICE_NAME || "store-catalog-api");
const catalogCacheRequests = metrics
  .getMeter("store-catalog-api")
  .createCounter("catalog.cache.requests", {
    description: "Catalog requests by Redis cache outcome",
    unit: "{request}",
  });

export const recordCatalogCacheRequest = (result) => {
  catalogCacheRequests.add(1, { "cache.result": result });
};

export const withRedisSpan = (operation, command) =>
  tracer.startActiveSpan(
    `redis.${operation}`,
    {
      kind: SpanKind.CLIENT,
      attributes: {
        "db.system.name": "redis",
        "db.operation.name": operation,
      },
    },
    async (span) => {
      try {
        return await command();
      } catch (error) {
        span.setStatus({ code: SpanStatusCode.ERROR });
        throw error;
      } finally {
        span.end();
      }
    },
  );

export const shutdownTelemetry = async () => {
  await sdk?.shutdown();
};
