import { connect } from "amqplib";
import { publishConfirmedMessage } from "./amqp.js";
import {
  assertReviewTopology,
  reviewCreatedRoutingKey,
  reviewEventsExchange,
} from "./review-queues.js";

let connection = null;
let channel = null;
let connectionPromise = null;

const reset = (activeConnection) => {
  if (connection === activeConnection) {
    connection = null;
    channel = null;
  }
};

const getPublisherChannel = async () => {
  if (channel) {
    return channel;
  }
  if (!connectionPromise) {
    connectionPromise = (async () => {
      const activeConnection = await connect(process.env.RABBITMQ_URL);
      connection = activeConnection;
      activeConnection.on("error", (error) => {
        console.error("RabbitMQ publisher connection failed:", error.message);
      });
      activeConnection.once("close", () => reset(activeConnection));

      try {
        const activeChannel = await activeConnection.createConfirmChannel();
        activeChannel.on("error", (error) => {
          console.error("RabbitMQ publisher channel failed:", error.message);
          void activeConnection.close().catch(() => {});
        });
        activeChannel.once("close", () => reset(activeConnection));
        await assertReviewTopology(activeChannel);
        channel = activeChannel;
        return activeChannel;
      } catch (error) {
        reset(activeConnection);
        await activeConnection.close().catch(() => {});
        throw error;
      }
    })().finally(() => {
      connectionPromise = null;
    });
  }
  return connectionPromise;
};

export const publishReview = async (review, idempotencyKey) => {
  const activeChannel = await getPublisherChannel();
  const event = Buffer.from(JSON.stringify({ version: 1, review }));
  await publishConfirmedMessage(
    activeChannel,
    reviewEventsExchange,
    reviewCreatedRoutingKey,
    event,
    {
      contentType: "application/json",
      messageId: idempotencyKey,
    },
  );
};

export const closeReviewPublisher = async () => {
  const activeConnection = connection;
  connection = null;
  channel = null;
  await activeConnection?.close();
};
