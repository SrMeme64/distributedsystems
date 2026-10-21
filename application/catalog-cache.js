import { randomUUID } from "node:crypto";
import { setTimeout as sleep } from "node:timers/promises";

const lockTtlMilliseconds = 30_000;
const releaseLockScript = `
  if redis.call("get", KEYS[1]) == ARGV[1] then
    return redis.call("del", KEYS[1])
  end
  return 0
`;

export const getCachedOrLoad = async ({ redis, cacheKey, ttlSeconds, load }) => {
  if (!Number.isSafeInteger(ttlSeconds) || ttlSeconds < 1) {
    throw new RangeError("Cache TTL must be a positive integer");
  }

  const lockKey = `${cacheKey}:lock`;
  while (true) {
    const cached = await redis.get(cacheKey);
    if (cached !== null) {
      return { value: JSON.parse(cached), cacheHit: true };
    }

    const lockToken = randomUUID();
    const lockAcquired = await redis.set(lockKey, lockToken, {
      NX: true,
      PX: lockTtlMilliseconds,
    });
    if (lockAcquired !== "OK") {
      await sleep(50);
      continue;
    }

    try {
      const cachedAfterLock = await redis.get(cacheKey);
      if (cachedAfterLock !== null) {
        return { value: JSON.parse(cachedAfterLock), cacheHit: true };
      }

      const value = await load();
      await redis.set(cacheKey, JSON.stringify(value), { EX: ttlSeconds });
      return { value, cacheHit: false };
    } finally {
      await redis.eval(releaseLockScript, {
        keys: [lockKey],
        arguments: [lockToken],
      });
    }
  }
};
