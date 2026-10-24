import { createClient, createSentinel } from "redis";

const connectTimeout = Number(process.env.REDIS_CONNECT_TIMEOUT_MS || 3000);

const parseSentinels = (value) => {
  const nodes = value
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry) => {
      const [host, port] = entry.split(":");
      if (!host) {
        throw new Error(`Invalid Redis sentinel entry: ${entry}`);
      }
      return { host, port: Number(port || 26379) };
    });

  if (nodes.length === 0) {
    throw new Error("REDIS_SENTINELS does not contain any node");
  }
  return nodes;
};

/**
 * Connects to Redis through Sentinel when REDIS_SENTINELS is configured.
 * Returns an object with a `client` that supports the regular commands and a
 * `close` function, so the rest of the application does not need to know
 * whether the topology is direct or Sentinel-managed.
 */
export const createRedisConnection = async () => {
  const sentinels = process.env.REDIS_SENTINELS?.trim();

  if (!sentinels) {
    const client = createClient({
      socket: {
        host: process.env.REDIS_HOST || "redis",
        port: Number(process.env.REDIS_PORT || 6379),
        connectTimeout,
      },
      disableOfflineQueue: true,
    });
    client.on("error", (error) => console.error("Redis client error:", error.message));
    await client.connect();
    return { client, mode: "direct", close: () => client.close() };
  }

  const sentinel = createSentinel({
    name: process.env.REDIS_MASTER_NAME || "mymaster",
    sentinelRootNodes: parseSentinels(sentinels),
    nodeClientOptions: {
      socket: { connectTimeout },
      disableOfflineQueue: true,
    },
    sentinelClientOptions: {
      socket: { connectTimeout },
    },
    passthroughClientErrorEvents: true,
    scanInterval: Number(process.env.REDIS_SENTINEL_SCAN_INTERVAL_MS || 5000),
  });

  sentinel.on("error", (error) =>
    console.error("Redis sentinel error:", error?.message ?? error),
  );

  await sentinel.connect();
  return { client: sentinel, mode: "sentinel", close: () => sentinel.close() };
};
