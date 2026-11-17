import {
  context,
  propagation,
  SpanKind,
  SpanStatusCode,
  trace,
} from "@opentelemetry/api";

const tracer = trace.getTracer(process.env.OTEL_SERVICE_NAME || "store-catalog-api");

const withAmqpSpan = (name, kind, destination, operation, callback) =>
  tracer.startActiveSpan(
    name,
    {
      kind,
      attributes: {
        "messaging.system": "rabbitmq",
        "messaging.destination.name": destination,
        "messaging.operation.type": operation,
      },
    },
    async (span) => {
      try {
        return await callback(span);
      } catch (error) {
        span.setStatus({ code: SpanStatusCode.ERROR });
        throw error;
      } finally {
        span.end();
      }
    },
  );

export const publishConfirmedMessage = async (
  channel,
  exchange,
  routingKey,
  content,
  properties,
) =>
  withAmqpSpan(
    `rabbitmq publish ${routingKey}`,
    SpanKind.PRODUCER,
    routingKey,
    "publish",
    async () => {
      const headers = { ...properties.headers };
      propagation.inject(context.active(), headers);
      channel.publish(exchange, routingKey, content, {
        ...properties,
        headers,
        persistent: true,
      });
      await channel.waitForConfirms();
    },
  );

export const withReviewConsumerSpan = (message, callback) => {
  const parentContext = propagation.extract(
    context.active(),
    message.properties.headers ?? {},
  );
  return context.with(parentContext, () =>
    withAmqpSpan(
      "rabbitmq process reviews.created",
      SpanKind.CONSUMER,
      "reviews.created",
      "process",
      callback,
    ),
  );
};
