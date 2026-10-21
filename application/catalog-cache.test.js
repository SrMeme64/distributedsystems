import assert from "node:assert/strict";
import test from "node:test";
import { getCachedOrLoad } from "./catalog-cache.js";

const createRedisMock = () => {
  const values = new Map();
  const writes = [];
  return {
    values,
    writes,
    async get(key) {
      return values.get(key) ?? null;
    },
    async set(key, value, options = {}) {
      if (options.NX && values.has(key)) {
        return null;
      }
      values.set(key, value);
      writes.push({ key, options });
      return "OK";
    },
    async eval(_script, { keys, arguments: [token] }) {
      if (values.get(keys[0]) === token) {
        values.delete(keys[0]);
      }
    },
  };
};

test("returns cached values without loading from the database", async () => {
  const redis = createRedisMock();
  redis.values.set("products", JSON.stringify([{ sku: "ST-001" }]));

  const result = await getCachedOrLoad({
    redis,
    cacheKey: "products",
    ttlSeconds: 60,
    load: async () => assert.fail("load should not be called"),
  });

  assert.deepEqual(result, {
    value: [{ sku: "ST-001" }],
    cacheHit: true,
  });
});

test("loads and stores a cache miss using the configured TTL", async () => {
  const redis = createRedisMock();
  const result = await getCachedOrLoad({
    redis,
    cacheKey: "products",
    ttlSeconds: 45,
    load: async () => [{ sku: "ST-002" }],
  });

  assert.deepEqual(result, {
    value: [{ sku: "ST-002" }],
    cacheHit: false,
  });
  assert.equal(redis.values.get("products"), JSON.stringify([{ sku: "ST-002" }]));
  assert.deepEqual(redis.writes.at(-1), {
    key: "products",
    options: { EX: 45 },
  });
});

test("coalesces simultaneous cache misses into one database load", async () => {
  const redis = createRedisMock();
  let loadCount = 0;
  const load = async () => {
    loadCount += 1;
    await new Promise((resolve) => setTimeout(resolve, 75));
    return [{ sku: "ST-003" }];
  };

  const results = await Promise.all(
    Array.from({ length: 8 }, () =>
      getCachedOrLoad({
        redis,
        cacheKey: "products",
        ttlSeconds: 60,
        load,
      }),
    ),
  );

  assert.equal(loadCount, 1);
  assert.ok(results.every(({ value }) => value[0].sku === "ST-003"));
});

test("releases its lock when the database load fails", async () => {
  const redis = createRedisMock();
  await assert.rejects(
    getCachedOrLoad({
      redis,
      cacheKey: "products",
      ttlSeconds: 60,
      load: async () => {
        throw new Error("database unavailable");
      },
    }),
    /database unavailable/,
  );

  const result = await getCachedOrLoad({
    redis,
    cacheKey: "products",
    ttlSeconds: 60,
    load: async () => [{ sku: "ST-004" }],
  });
  assert.equal(result.value[0].sku, "ST-004");
});
