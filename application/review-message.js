const idempotencyKeyPattern = /^[A-Za-z0-9._:-]{1,128}$/;

export class InvalidReviewMessageError extends Error {}

export const isValidReviewIdempotencyKey = (value) =>
  typeof value === "string" && idempotencyKeyPattern.test(value);

export const parseReviewMessage = (message) => {
  const idempotencyKey = message.properties.messageId;
  if (!isValidReviewIdempotencyKey(idempotencyKey)) {
    throw new InvalidReviewMessageError("Review message has an invalid idempotency key");
  }

  let event;
  try {
    event = JSON.parse(message.content.toString("utf8"));
  } catch {
    throw new InvalidReviewMessageError("Review message is not valid JSON");
  }

  if (event?.version !== 1 || event.review === null || typeof event.review !== "object") {
    throw new InvalidReviewMessageError("Review message has an unsupported schema");
  }

  const { sku, reviewer, rating, comment, createdAt } = event.review;
  const date = new Date(createdAt);
  if (
    typeof sku !== "string" ||
    !/^[A-Za-z0-9-]+$/.test(sku) ||
    typeof reviewer !== "string" ||
    reviewer.length < 1 ||
    reviewer.length > 80 ||
    !Number.isInteger(rating) ||
    rating < 1 ||
    rating > 5 ||
    typeof comment !== "string" ||
    comment.length < 1 ||
    comment.length > 1000 ||
    !Number.isFinite(date.getTime())
  ) {
    throw new InvalidReviewMessageError("Review message contains invalid review data");
  }

  return {
    sampleId: idempotencyKey,
    sku,
    reviewer,
    rating,
    comment,
    createdAt: date,
  };
};

export const reviewRetryCount = (headers = {}) => {
  const count = headers["x-retry-count"] ?? 0;
  if (!Number.isInteger(count) || count < 0) {
    throw new InvalidReviewMessageError("Review message has an invalid retry count");
  }
  return count;
};
