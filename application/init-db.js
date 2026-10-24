import { readFile } from "node:fs/promises";
import { MongoClient } from "mongodb";
import mysql from "mysql2/promise";
import { buildMongoUri } from "./mongo-config.js";

const required = (name) => {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
};

const connectToMariaDb = async () => {
  for (let attempt = 1; attempt <= 30; attempt += 1) {
    try {
      return await mysql.createConnection({
        host: required("DB_HOST"),
        port: Number(process.env.DB_PORT || 3306),
        database: required("DB_NAME"),
        user: required("DB_USER"),
        password: required("DB_PASSWORD"),
        multipleStatements: true,
      });
    } catch (error) {
      if (
        !["ECONNREFUSED", "ETIMEDOUT", "EHOSTUNREACH", "EAI_AGAIN", "ENOTFOUND"].includes(
          error.code,
        ) ||
        attempt === 30
      ) {
        throw error;
      }
      console.log(`MariaDB is not ready; retrying (${attempt}/30)`);
      await new Promise((resolve) => setTimeout(resolve, 2000));
    }
  }
  throw new Error("MariaDB connection retry limit reached");
};

const connection = await connectToMariaDb();
const mongoDatabase = required("MONGO_DB");
const mongoAddress = buildMongoUri();
const mongoAdmin = new MongoClient(
  mongoAddress,
  {
    auth: {
      username: required("MONGO_ADMIN_USER"),
      password: required("MONGO_ADMIN_PASSWORD"),
    },
    authSource: "admin",
  },
);

try {
  const schema = await readFile(new URL("./database/catalog.sql", import.meta.url), "utf8");
  await connection.query(schema);
  console.log("Product catalog schema initialized");
} finally {
  await connection.end();
}

try {
  await mongoAdmin.connect();
  const database = mongoAdmin.db(mongoDatabase);
  const applicationUser = required("MONGO_USER");
  const applicationPassword = required("MONGO_PASSWORD");
  const users = await database.command({ usersInfo: applicationUser });
  const roles = [{ role: "readWrite", db: mongoDatabase }];
  if (users.users.length > 0) {
    await database.command({
      updateUser: applicationUser,
      pwd: applicationPassword,
      roles,
    });
  } else {
    await database.command({
      createUser: applicationUser,
      pwd: applicationPassword,
      roles,
    });
  }
  console.log("MongoDB application user is ready");
} finally {
  await mongoAdmin.close();
}

const mongo = new MongoClient(mongoAddress, {
  auth: {
    username: required("MONGO_USER"),
    password: required("MONGO_PASSWORD"),
  },
  authSource: mongoDatabase,
});

try {
  await mongo.connect();
  const reviews = mongo.db(mongoDatabase).collection("product_reviews");
  await reviews.createIndex({ sku: 1, createdAt: -1 });
  await reviews.updateOne(
    { sampleId: "sample-st-001" },
    {
      $setOnInsert: {
        sampleId: "sample-st-001",
        sku: "ST-001",
        reviewer: "Alex",
        rating: 5,
        comment: "Sturdy and convenient for grocery shopping.",
        createdAt: new Date("2025-01-15T12:00:00.000Z"),
      },
    },
    { upsert: true },
  );
  await reviews.updateOne(
    { sampleId: "sample-st-003" },
    {
      $setOnInsert: {
        sampleId: "sample-st-003",
        sku: "ST-003",
        reviewer: "Sam",
        rating: 4,
        comment: "A comfortable everyday mug.",
        createdAt: new Date("2025-01-16T12:00:00.000Z"),
      },
    },
    { upsert: true },
  );
  await reviews.createIndex({ sampleId: 1 }, { unique: true, sparse: true });
  console.log("Product reviews initialized in MongoDB");
} finally {
  await mongo.close();
}