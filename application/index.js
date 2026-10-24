import { createServer } from "node:http";
import { MongoClient } from "mongodb";
import mysql from "mysql2/promise";
import { getCatalog } from "./catalog-cache.js";
import { buildMongoUri } from "./mongo-config.js";
import { createRedisConnection } from "./redis-client.js";

const required = (name) => {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
};

const positiveInteger = (name, fallback, maximum = Number.MAX_SAFE_INTEGER) => {
  const value = Number(process.env[name] || fallback);
  if (!Number.isSafeInteger(value) || value < 1 || value > maximum) {
    throw new Error(`${name} must be an integer between 1 and ${maximum}`);
  }
  return value;
};

const poolSize = positiveInteger("DB_POOL_SIZE", 10, 100);
const pool = mysql.createPool({
  host: required("DB_HOST"),
  port: Number(process.env.DB_PORT || 3306),
  database: required("DB_NAME"),
  user: required("DB_USER"),
  password: required("DB_PASSWORD"),
  waitForConnections: true,
  connectionLimit: poolSize,
  maxIdle: poolSize,
  idleTimeout: positiveInteger("DB_POOL_IDLE_TIMEOUT_MS", 60_000),
  connectTimeout: positiveInteger("DB_CONNECT_TIMEOUT_MS", 5_000),
  enableKeepAlive: true,
  keepAliveInitialDelay: 10_000,
});

const mongoDatabase = required("MONGO_DB");
const mongoOptions = {
  auth: {
    username: required("MONGO_USER"),
    password: required("MONGO_PASSWORD"),
  },
  authSource: mongoDatabase,
  serverSelectionTimeoutMS: positiveInteger("MONGO_SERVER_SELECTION_TIMEOUT_MS", 5_000),
};
const createMongoClient = () => new MongoClient(buildMongoUri(), mongoOptions);

let mongo = createMongoClient();
let mongoConnecting = null;

// The driver closes the topology when connect() fails but keeps the client
// attached to it, so the same client cannot retry. Replace it on failure so a
// request after the replica set recovers opens a fresh connection.
const getMongo = () => {
  if (mongoConnecting) {
    return mongoConnecting;
  }
  mongoConnecting = (async () => {
    try {
      await mongo.connect();
      return mongo;
    } catch (error) {
      const failed = mongo;
      mongo = createMongoClient();
      void failed.close().catch(() => {});
      throw error;
    } finally {
      mongoConnecting = null;
    }
  })();
  return mongoConnecting;
};

let redisConnection = null;
let redisConnecting = false;

const connectRedis = async () => {
  if (redisConnecting) {
    return;
  }
  redisConnecting = true;
  try {
    redisConnection = await createRedisConnection();
    console.log(`Redis cache connected (${redisConnection.mode})`);
  } catch (error) {
    redisConnection = null;
    console.error("Redis cache unavailable; catalog reads will use MariaDB:", error.message);
  } finally {
    redisConnecting = false;
  }
};

const withTimeout = (promise, milliseconds, label) => {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`${label} timed out after ${milliseconds} ms`)),
      milliseconds,
    );
    timer.unref?.();
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
};

const redisCommandTimeout = positiveInteger("REDIS_COMMAND_TIMEOUT_MS", 2_000, 60_000);

// A Sentinel client keeps its last known master and can leave commands waiting
// while it reconnects. The cache is disposable, so every command gets a short
// deadline and the catalog falls back to MariaDB instead of stalling the API.
const withRedisTimeout = (client) => ({
  get isReady() {
    return client.isReady;
  },
  get: (key) => withTimeout(client.get(key), redisCommandTimeout, "Redis GET"),
  set: (...args) => withTimeout(client.set(...args), redisCommandTimeout, "Redis SET"),
  eval: (...args) => withTimeout(client.eval(...args), redisCommandTimeout, "Redis EVAL"),
  del: (...args) => withTimeout(client.del(...args), redisCommandTimeout, "Redis DEL"),
  ping: () => withTimeout(client.ping(), redisCommandTimeout, "Redis PING"),
});

class HttpError extends Error {
  constructor(statusCode, message, trace) {
    super(message);
    this.statusCode = statusCode;
    this.trace = trace;
  }
}

const readJsonBody = async (request) => {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 16_384) {
      throw new HttpError(413, "Request body is too large");
    }
    chunks.push(chunk);
  }

  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new HttpError(400, "Request body must be valid JSON");
  }
};

const sendJson = (response, statusCode, payload, trace = []) => {
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "x-request-trace": trace.join(" -> "),
  });
  response.end(JSON.stringify(payload));
};

const start = async () => {
  // Warm up MongoDB in the background. The API must start even if the replica
  // set is still electing a primary, and getMongo() retries on later requests.
  void getMongo()
    .then(() => console.log("MongoDB replica set connected"))
    .catch((error) =>
      console.error("MongoDB is not reachable at startup; reviews will fail until it recovers:", error.message),
    );

  const productsCacheKey = "store:products:cheapest";
  const cacheTtlSeconds = positiveInteger("CATALOG_CACHE_TTL_SECONDS", 60);

  await connectRedis();
  const redisRetry = setInterval(() => {
    if (!redisConnection) {
      void connectRedis();
    }
  }, positiveInteger("REDIS_RETRY_INTERVAL_MS", 15_000));
  redisRetry.unref();

  const activeRedis = () =>
    redisConnection?.client.isReady ? withRedisTimeout(redisConnection.client) : null;

  const server = createServer((request, response) => {
    const trace = [
      request.headers["x-presentation-lb"] || "presentation-lb-unknown",
      request.headers["x-web-node"] || "web-node-unknown",
      request.headers["x-application-lb"] || "application-lb-unknown",
      process.env.APPLICATION_NODE || "app-node-unknown",
    ];
    void (async () => {
      const pathname = new URL(request.url, "http://localhost").pathname;

      if (request.method === "GET" && pathname === "/health") {
        const redis = activeRedis();
        const checks = await Promise.allSettled([
          withTimeout(pool.query("SELECT 1"), 2_000, "MariaDB health check"),
          withTimeout(
            getMongo().then((client) => client.db().command({ ping: 1 })),
            1_500,
            "MongoDB health check",
          ),
          redis
            ? withTimeout(redis.ping(), 500, "Redis health check")
            : Promise.reject(new Error("Redis is not ready")),
        ]);

        const dependencies = {
          mariadb: checks[0].status === "fulfilled" ? "ok" : "unavailable",
          mongodb: checks[1].status === "fulfilled" ? "ok" : "unavailable",
          redis: checks[2].status === "fulfilled" ? "ok" : "unavailable",
        };
        const allOk = Object.values(dependencies).every((value) => value === "ok");
        const status =
          dependencies.mariadb !== "ok" ? "unavailable" : allOk ? "ok" : "degraded";

        // MariaDB is the only dependency that makes the API unusable. MongoDB
        // only affects reviews and Redis only affects performance, so the load
        // balancers must keep receiving 200 while those two recover.
        sendJson(
          response,
          dependencies.mariadb === "ok" ? 200 : 503,
          { status, dependencies },
          [...trace, "mariadb", "mongodb", "redis"],
        );
        return;
      }

      if (request.method === "GET" && pathname === "/") {
        sendJson(response, 200, {
          service: "store-catalog-api",
          products: "/products/cheapest",
          reviews: "/products/{sku}/reviews",
        }, trace);
        return;
      }

      if (request.method === "GET" && pathname === "/products/cheapest") {
        const loadCatalog = async () => {
          const [rows] = await pool.execute(
            "SELECT id, sku, name, description, price FROM products ORDER BY price ASC, id ASC LIMIT 10",
          );
          return rows;
        };

        const redis = activeRedis();
        if (!redis) {
          trace.push("mariadb", "redis (unavailable)");
          const products = await loadCatalog();
          sendJson(response, 200, products, trace);
          return;
        }

        let cacheFailed = false;
        trace.push("redis");
        const { value: products, cacheHit, cacheAvailable } = await getCatalog({
          redis,
          cacheKey: productsCacheKey,
          ttlSeconds: cacheTtlSeconds,
          load: async () => {
            trace[trace.length - 1] = cacheFailed
              ? "redis (unavailable)"
              : "redis (cache miss)";
            trace.push("mariadb");
            return loadCatalog();
          },
          onCacheError: (error) => {
            cacheFailed = true;
            console.error("Catalog cache unavailable; serving from MariaDB:", error.message);
          },
        });

        if (cacheHit) {
          trace.push("cache hit");
        } else if (cacheAvailable) {
          trace.push("redis (cache write)");
        }
        sendJson(response, 200, products, trace);
        return;
      }

      if (request.method === "POST" && pathname === "/cache/clear") {
        const redis = activeRedis();
        if (!redis) {
          throw new HttpError(503, "Catalog cache is unavailable", trace);
        }

        let removed;
        try {
          removed = await redis.del(productsCacheKey);
        } catch (error) {
          console.error("Could not clear the catalog cache:", error.message);
          throw new HttpError(503, "Catalog cache is unavailable", trace);
        }

        sendJson(
          response,
          200,
          { cacheKey: productsCacheKey, cacheEntryRemoved: removed === 1 },
          [...trace, "redis (delete catalog cache)"],
        );
        return;
      }

      const reviewMatch = pathname.match(/^\/products\/([A-Za-z0-9-]+)\/reviews$/);
      if (reviewMatch && request.method === "GET") {
        const productSku = reviewMatch[1];
        const client = await getMongo();
        const productReviews = await client
          .db(mongoDatabase)
          .collection("product_reviews")
          .find({ sku: productSku })
          .sort({ createdAt: -1 })
          .limit(50)
          .project({ _id: 0, reviewer: 1, rating: 1, comment: 1, createdAt: 1 })
          .toArray();
        sendJson(response, 200, { sku: productSku, reviews: productReviews }, [...trace, "mongodb"]);
        return;
      }

      if (reviewMatch && request.method === "POST") {
        if (!request.headers["content-type"]?.includes("application/json")) {
          throw new HttpError(415, "Content-Type must be application/json");
        }
        const body = await readJsonBody(request);
        if (body === null || typeof body !== "object" || Array.isArray(body)) {
          throw new HttpError(400, "Request body must be a JSON object");
        }
        const reviewer = typeof body.reviewer === "string" ? body.reviewer.trim() : "";
        const comment = typeof body.comment === "string" ? body.comment.trim() : "";
        if (
          reviewer.length < 1 ||
          reviewer.length > 80 ||
          !Number.isInteger(body.rating) ||
          body.rating < 1 ||
          body.rating > 5 ||
          comment.length < 1 ||
          comment.length > 1000
        ) {
          throw new HttpError(400, "Provide reviewer, rating (1-5), and comment within the allowed lengths");
        }
        trace.push("mariadb (product lookup)");
        const [matches] = await pool.execute("SELECT 1 FROM products WHERE sku = ? LIMIT 1", [
          reviewMatch[1],
        ]);
        if (matches.length === 0) {
          throw new HttpError(404, "Product not found", trace);
        }
        const review = {
          sku: reviewMatch[1],
          reviewer,
          rating: body.rating,
          comment,
          createdAt: new Date(),
        };
        const client = await getMongo();
        const result = await client
          .db(mongoDatabase)
          .collection("product_reviews")
          .insertOne(review);
        sendJson(response, 201, { id: result.insertedId.toString(), ...review }, [...trace, "mongodb (insert review)"]);
        return;
      }

      sendJson(response, 404, { error: "Not found" }, trace);
    })().catch((error) => {
      if (!(error instanceof HttpError)) {
        console.error("Request failed:", error);
      }
      if (response.headersSent) {
        response.destroy();
        return;
      }
      sendJson(
        response,
        error instanceof HttpError ? error.statusCode : 503,
        { error: error instanceof HttpError ? error.message : "Service temporarily unavailable" },
        error instanceof HttpError && error.trace ? error.trace : trace,
      );
    });
  });

  server.listen(8080, "0.0.0.0", () => {
    console.log("Store catalog API listening on port 8080");
  });

  const shutdown = () => {
    clearInterval(redisRetry);
    server.close(() => {
      void Promise.allSettled([
        pool.end(),
        mongo.close(),
        redisConnection ? redisConnection.close() : Promise.resolve(),
      ]).then(() => process.exit(0));
    });
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
};

start().catch((error) => {
  console.error("Application startup failed:", error);
  process.exitCode = 1;
});
