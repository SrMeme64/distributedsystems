const required = (name) => {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
};

/**
 * Builds the MongoDB connection string from either a comma separated
 * MONGO_HOSTS list (replica set) or a single MONGO_HOST (standalone/local).
 */
export const buildMongoUri = () => {
  const hosts = (process.env.MONGO_HOSTS || process.env.MONGO_HOST || "")
    .split(",")
    .map((host) => host.trim())
    .filter(Boolean);
  if (hosts.length === 0) {
    throw new Error("Missing required environment variable: MONGO_HOSTS or MONGO_HOST");
  }

  const port = Number(process.env.MONGO_PORT || 27017);
  const database = required("MONGO_DB");
  const replicaSet = process.env.MONGO_REPLICA_SET?.trim();
  const query = replicaSet ? `?replicaSet=${encodeURIComponent(replicaSet)}` : "";

  return `mongodb://${hosts.map((host) => `${host}:${port}`).join(",")}/${encodeURIComponent(database)}${query}`;
};
