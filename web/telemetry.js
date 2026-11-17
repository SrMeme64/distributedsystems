import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { FetchInstrumentation } from "@opentelemetry/instrumentation-fetch";
import { registerInstrumentations } from "@opentelemetry/instrumentation";
import { resourceFromAttributes } from "@opentelemetry/resources";
import { BatchSpanProcessor, WebTracerProvider } from "@opentelemetry/sdk-trace-web";
import { W3CTraceContextPropagator } from "@opentelemetry/core";

const provider = new WebTracerProvider({
  resource: resourceFromAttributes({ "service.name": "store-web" }),
  spanProcessors: [
    new BatchSpanProcessor(
      new OTLPTraceExporter({
        url: new URL("/otlp/v1/traces", window.location.href).toString(),
      }),
    ),
  ],
});

provider.register({ propagator: new W3CTraceContextPropagator() });

registerInstrumentations({
  instrumentations: [
    new FetchInstrumentation({
      ignoreUrls: [/\/otlp\/v1\/traces(?:\?.*)?$/],
      propagateTraceHeaderCorsUrls: [/\/api(?:\/|$)/],
    }),
  ],
});
