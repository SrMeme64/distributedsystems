export const reviewEventsExchange = "reviews.events";
export const reviewCreatedQueue = "reviews.created";
export const reviewCreatedRoutingKey = "reviews.created";
export const reviewRetryExchange = "reviews.retry";
export const reviewRetryQueue = "reviews.retry";
export const reviewRetryRoutingKey = "reviews.retry";
export const reviewDeadLetterExchange = "reviews.dlx";
export const reviewDeadLetterQueue = "reviews.dlq";
export const reviewDeadLetterRoutingKey = "reviews.dead";
export const maxReviewRetries = 3;

export const assertReviewTopology = async (channel) => {
  await channel.assertExchange(reviewEventsExchange, "direct", { durable: true });
  await channel.assertExchange(reviewRetryExchange, "direct", { durable: true });
  await channel.assertExchange(reviewDeadLetterExchange, "direct", { durable: true });

  await channel.assertQueue(reviewCreatedQueue, {
    durable: true,
    arguments: {
      "x-max-length": 10_000,
      "x-overflow": "reject-publish",
    },
  });
  await channel.assertQueue(reviewRetryQueue, {
    durable: true,
    arguments: {
      "x-message-ttl": 5_000,
      "x-dead-letter-exchange": reviewEventsExchange,
      "x-dead-letter-routing-key": reviewCreatedRoutingKey,
    },
  });
  await channel.assertQueue(reviewDeadLetterQueue, {
    durable: true,
  });

  await channel.bindQueue(reviewCreatedQueue, reviewEventsExchange, reviewCreatedRoutingKey);
  await channel.bindQueue(reviewRetryQueue, reviewRetryExchange, reviewRetryRoutingKey);
  await channel.bindQueue(
    reviewDeadLetterQueue,
    reviewDeadLetterExchange,
    reviewDeadLetterRoutingKey,
  );
};
