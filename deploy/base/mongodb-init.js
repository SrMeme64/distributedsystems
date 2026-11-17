const databaseName = process.env.MONGO_INITDB_DATABASE;
const applicationUser = process.env.MONGO_APP_USERNAME;
const reviews = db.getSiblingDB(databaseName);

if (!reviews.getUser(applicationUser)) {
  reviews.createUser({
    user: applicationUser,
    pwd: process.env.MONGO_APP_PASSWORD,
    roles: [{ role: "readWrite", db: databaseName }],
  });
}

const productReviews = reviews.getCollection("product_reviews");
productReviews.createIndex({ sku: 1, createdAt: -1 });
productReviews.createIndex({ sampleId: 1 }, { unique: true, sparse: true });
productReviews.updateOne(
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
productReviews.updateOne(
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
