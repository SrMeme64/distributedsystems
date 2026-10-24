import assert from "node:assert/strict";
import test from "node:test";
import { buildMongoUri } from "./mongo-config.js";

const setEnvironment = ({ hosts, host, replicaSet }) => {
  delete process.env.MONGO_HOSTS;
  delete process.env.MONGO_HOST;
  delete process.env.MONGO_REPLICA_SET;
  process.env.MONGO_DB = "store_reviews";
  process.env.MONGO_PORT = "27017";
  if (hosts !== undefined) {
    process.env.MONGO_HOSTS = hosts;
  }
  if (host !== undefined) {
    process.env.MONGO_HOST = host;
  }
  if (replicaSet !== undefined) {
    process.env.MONGO_REPLICA_SET = replicaSet;
  }
};

test("builds a replica set URI from a comma separated host list", () => {
  setEnvironment({ hosts: "mongo1, mongo2,mongo3", replicaSet: "rs0" });
  assert.equal(
    buildMongoUri(),
    "mongodb://mongo1:27017,mongo2:27017,mongo3:27017/store_reviews?replicaSet=rs0",
  );
});

test("falls back to a single host when no replica set is configured", () => {
  setEnvironment({ host: "mongo", replicaSet: "" });
  assert.equal(buildMongoUri(), "mongodb://mongo:27017/store_reviews");
});

test("rejects a configuration without hosts", () => {
  setEnvironment({});
  assert.throws(() => buildMongoUri(), /MONGO_HOSTS or MONGO_HOST/);
});
