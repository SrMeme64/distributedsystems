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

/**
 * Reads the catalog through the cache. If Redis is unavailable the catalog is
 * served directly from MariaDB: the cache is disposable and must never turn a
 * database read into an API failure. Errors raised by `load` itself are
 * propagated so a database outage is not mistaken for a cache outage.
 */
export const getCatalog = async ({ redis, cacheKey, ttlSeconds, load, onCacheError }) => {
  let loadError;
  let loadedValue;
  let loadCompleted = false;

  const loadOnce = async () => {
    try {
      loadedValue = await load();
      loadCompleted = true;
      return loadedValue;
    } catch (error) {
      loadError = error;
      throw error;
    }
  };

  try {
    const result = await getCachedOrLoad({
      redis,
      cacheKey,
      ttlSeconds,
      load: loadOnce,
    });
    return { ...result, cacheAvailable: true };
  } catch (error) {
    if (loadError) {
      throw loadError;
    }
    onCacheError?.(error);
    // If the database read already succeeded and only the cache write failed,
    // reuse that result instead of querying MariaDB a second time.
    const value = loadCompleted ? loadedValue : await load();
    return { value, cacheHit: false, cacheAvailable: false };
  }
};
