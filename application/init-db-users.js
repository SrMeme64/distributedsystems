import mysql from "mysql2/promise";

const required = (name) => {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
};

const hosts = (process.env.DB_BOOTSTRAP_HOSTS || process.env.DB_BOOTSTRAP_HOST || "galera1")
  .split(",")
  .map((host) => host.trim())
  .filter(Boolean);

if (hosts.length === 0) {
  throw new Error("DB_BOOTSTRAP_HOSTS must contain at least one host");
}

const port = Number(process.env.DB_PORT || 3306);
const adminUser = required("DB_ADMIN_USER");
const adminPassword = required("DB_ADMIN_PASSWORD");
const monitorUser = process.env.PROXYSQL_MONITOR_USER || "proxysql_monitor";
const monitorPassword = required("PROXYSQL_MONITOR_PASSWORD");

if (!/^[A-Za-z0-9_]+$/.test(monitorUser)) {
  throw new Error("PROXYSQL_MONITOR_USER must contain only letters, digits and underscores");
}

const connect = async () => {
  for (let attempt = 1; attempt <= 30; attempt += 1) {
    // Cycle through the Galera nodes so a single unavailable node does not
    // block the creation of the ProxySQL monitoring user.
    const host = hosts[(attempt - 1) % hosts.length];
    try {
      const connection = await mysql.createConnection({
        host,
        port,
        user: adminUser,
        password: adminPassword,
        multipleStatements: false,
      });
      return { connection, host };
    } catch (error) {
      if (
        !["ECONNREFUSED", "ETIMEDOUT", "EHOSTUNREACH", "EAI_AGAIN", "ENOTFOUND"].includes(
          error.code,
        ) ||
        attempt === 30
      ) {
        throw error;
      }
      console.log(`MariaDB bootstrap host ${host} is not ready; retrying (${attempt}/30)`);
      await new Promise((resolve) => setTimeout(resolve, 2000));
    }
  }
  throw new Error("MariaDB bootstrap retry limit reached");
};

const { connection, host } = await connect();

try {
  const quotedUser = connection.escape(monitorUser);
  const quotedPassword = connection.escape(monitorPassword);

  await connection.query(
    `CREATE USER IF NOT EXISTS ${quotedUser}@'%' IDENTIFIED BY ${quotedPassword}`,
  );
  await connection.query(`ALTER USER ${quotedUser}@'%' IDENTIFIED BY ${quotedPassword}`);
  await connection.query(
    `GRANT USAGE, PROCESS, REPLICATION CLIENT ON *.* TO ${quotedUser}@'%'`,
  );
  console.log(`ProxySQL monitor user ${monitorUser} is ready on ${host}`);
} finally {
  await connection.end();
}
