import { createServer } from "node:http";
import { setTimeout as sleep } from "node:timers/promises";
import { SpanStatusCode } from "@opentelemetry/api";
import { connect } from "amqplib";
import { MongoClient } from "mongodb";
import { publishConfirmedMessage, withReviewConsumerSpan } from "./amqp.js";
import { buildMongoUri } from "./mongo-config.js";
import {
  assertReviewTopology,
  maxReviewRetries,
  reviewCreatedQueue,
  reviewDeadLetterExchange,
  reviewDeadLetterRoutingKey,
  reviewRetryExchange,
  reviewRetryRoutingKey,
} from "./review-queues.js";
import {
  InvalidReviewMessageError,
  parseReviewMessage,
  reviewRetryCount,
} from "./review-message.js";

const mongoDatabase = process.env.MONGO_DB;
const createMongoClient = () =>
  new MongoClient(buildMongoUri(), {
    auth: {
      username: process.env.MONGO_USER,
      password: process.env.MONGO_PASSWORD,
    },
    authSource: mongoDatabase,
    serverSelectionTimeoutMS: 5_000,
  });
let mongoClient = createMongoClient();
let mongoConnected = false;

let ready = false;
let stopping = false;
let currentConnection = null;
let currentChannel = null;

const healthServer = createServer((request, response) => {
  const path = new URL(request.url, "http://localhost").pathname;
  if (path === "/healthz") {
    response.writeHead(200).end();
    return;
  }
  if (path === "/readyz") {
    response.writeHead(ready ? 200 : 503).end();
    return;
  }
  response.writeHead(404).end();
});

const republishMessage = async (channel, message, exchange, routingKey, headers) => {
  await publishConfirmedMessage(
    channel,
    exchange,
    routingKey,
    message.content,
    {
      contentType: message.properties.contentType || "application/json",
      messageId: message.properties.messageId,
      headers,
    },
  );
};

const routeFailedMessage = async (channel, message, error) => {
  let retryCount;
  try {
    retryCount = reviewRetryCount(message.properties.headers);
  } catch {
    retryCount = maxReviewRetries;
  }

  const headers = {
    ...message.properties.headers,
    "x-retry-count": retryCount,
    "x-failure-type": error instanceof InvalidReviewMessageError
      ? "invalid-message"
      : "processing-error",
  };
  if (error instanceof InvalidReviewMessageError || retryCount >= maxReviewRetries) {
    await republishMessage(
      channel,
      message,
      reviewDeadLetterExchange,
      reviewDeadLetterRoutingKey,
      headers,
    );
    console.error("Review message moved to the dead-letter queue.");
    return;
  }

  headers["x-retry-count"] = retryCount + 1;
  await republishMessage(
    channel,
    message,
    reviewRetryExchange,
    reviewRetryRoutingKey,
    headers,
  );
  console.error("Review persistence failed; message scheduled for retry.");
};

const processMessage = async (channel, message) =>
  withReviewConsumerSpan(message, async (span) => {
    try {
      const review = parseReviewMessage(message);
      await mongoClient.db(mongoDatabase).collection("product_reviews").insertOne(review);
    } catch (error) {
      if (error?.code === 11000) {
        return;
      }
      span.setStatus({ code: SpanStatusCode.ERROR });
      await routeFailedMessage(channel, message, error);
    }
  });

const waitForClose = (connection, channel) =>
  new Promise((resolve) => {
    let settled = false;
    const finish = () => {
      if (!settled) {
        settled = true;
        ready = false;
        resolve();
      }
    };
    connection.once("close", finish);
    channel.once("close", finish);
    connection.on("error", (error) => {
      ready = false;
      console.error("RabbitMQ worker connection failed:", error.message);
    });
    channel.on("error", (error) => {
      ready = false;
      console.error("RabbitMQ worker channel failed:", error.message);
    });
  });

const consumeForever = async () => {
  while (!stopping) {
    try {
      if (!mongoConnected) {
        try {
          await mongoClient.connect();
          mongoConnected = true;
        } catch (error) {
          const failedClient = mongoClient;
          mongoClient = createMongoClient();
          void failedClient.close().catch(() => {});
          throw error;
        }
      }
      const connection = await connect(process.env.RABBITMQ_URL);
      currentConnection = connection;
      connection.on("error", (error) => {
        ready = false;
        console.error("RabbitMQ worker connection failed:", error.message);
      });
      const channel = await connection.createConfirmChannel();
      currentChannel = channel;
      channel.on("error", (error) => {
        ready = false;
        console.error("RabbitMQ worker channel failed:", error.message);
      });
      await assertReviewTopology(channel);
      await channel.prefetch(1);
      await channel.consume(reviewCreatedQueue, (message) => {
        if (!message) {
          ready = false;
          return;
        }
        void processMessage(channel, message)
          .then(() => channel.ack(message))
          .catch((error) => {
            console.error("Review delivery could not be confirmed; restarting consumer channel:", error.message);
            void channel.close().catch(() => {});
          });
      });
      ready = true;
      console.log("Review worker consuming reviews.created");
      await waitForClose(connection, channel);
    } catch (error) {
      ready = false;
      if (!stopping) {
        console.error("Review worker connection unavailable; retrying:", error.message);
      }
    } finally {
      ready = false;
      const channel = currentChannel;
      const connection = currentConnection;
      currentChannel = null;
      currentConnection = null;
      await channel?.close().catch(() => {});
      await connection?.close().catch(() => {});
    }
    if (!stopping) {
      await sleep(2_000);
    }
  }
};

const port = Number(process.env.WORKER_HEALTH_PORT || 8081);
healthServer.listen(port, "0.0.0.0", () => {
  console.log(`Review worker health server listening on port ${port}`);
});

const shutdown = () => {
  stopping = true;
  ready = false;
  healthServer.close();
  void currentChannel?.close().catch(() => {});
  void currentConnection?.close().catch(() => {});
  void mongoClient.close().catch((error) => {
    console.error("Worker MongoDB shutdown failed:", error.message);
  });
};

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
void consumeForever();
