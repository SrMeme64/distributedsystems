import assert from "node:assert/strict";
import test from "node:test";
import {
  InvalidReviewMessageError,
  parseReviewMessage,
  reviewRetryCount,
} from "./review-message.js";

const message = (payload, messageId = "review-123") => ({
  properties: { messageId },
  content: Buffer.from(JSON.stringify(payload)),
});

test("parses a versioned review message and preserves its idempotency key", () => {
  const review = parseReviewMessage(
    message({
      version: 1,
      review: {
        sku: "ST-001",
        reviewer: "Alex",
        rating: 5,
        comment: "Helpful review",
        createdAt: "2025-01-15T12:00:00.000Z",
      },
    }),
  );

  assert.equal(review.sampleId, "review-123");
  assert.equal(review.sku, "ST-001");
  assert.equal(review.createdAt.toISOString(), "2025-01-15T12:00:00.000Z");
});

test("rejects malformed, unsupported, or invalid review messages", () => {
  assert.throws(
    () => parseReviewMessage({ properties: { messageId: "review-123" }, content: Buffer.from("{") }),
    InvalidReviewMessageError,
  );
  assert.throws(
    () => parseReviewMessage(message({ version: 2, review: {} })),
    InvalidReviewMessageError,
  );
  assert.throws(
    () => parseReviewMessage(message({ version: 1, review: {} }, "../invalid")),
    InvalidReviewMessageError,
  );
});

test("validates retry counters from AMQP headers", () => {
  assert.equal(reviewRetryCount({}), 0);
  assert.equal(reviewRetryCount({ "x-retry-count": 2 }), 2);
  assert.throws(
    () => reviewRetryCount({ "x-retry-count": -1 }),
    InvalidReviewMessageError,
  );
});
