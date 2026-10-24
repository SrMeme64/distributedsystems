# Pendientes de mejora del sistema distribuido

El stack es una demostración en un solo host. Compose es el entorno reproducible;
la segunda laptop se usa como cliente de las PoC LAN. No se declara alta
disponibilidad multinodo.

## Completado

- **Capa de datos:** ProxySQL (enrutamiento lectura/escritura, failover de writer),
  MongoDB replica set `rs0`, Redis Sentinel (maestro + 2 réplicas + 3 centinelas,
  quórum 2), caché descartable, pool parametrizado (`DB_POOL_SIZE`).
- **Resiliencia:** Sentinel con IP fija (`172.32.0.11`) para evitar `TILT`,
  `REDIS_COMMAND_TIMEOUT_MS`, fallback del catálogo a MariaDB,
  `timeout check 4s` en HAProxy, arranque de la API con MongoDB no disponible y
  reconexión automática, `galera/entrypoint.sh` para unir `galera1` cuando
  `safe_to_bootstrap=0`, `db-bootstrap` multi-host.
- **Nagios:** 23 hosts (proxysql, mongo1/2/3, redis-master/replica/sentinel).
- **Chaos Monkey:** grupos `proxysql`, `mongodb`, `redis-data`, `redis-sentinel`.
- **PoC 1, 2 y 3** recreadas con resultados documentados en el README.

## Pendiente

- Automatizar respaldos periódicos de MariaDB y probar restauración.
- Instrumentar con OpenTelemetry y centralizar logs/métricas/trazas.
- Añadir TLS en la entrada pública y autenticación/limitación de la API.
- Adoptar migraciones de base de datos.
- Documentar procedimientos de operación y recuperación.
- Dejar orquestación multinodo y failover entre hosts como evolución futura.

## Recuperación de Galera

Si todos los nodos están detenidos y ninguno tiene `safe_to_bootstrap=1`,
`mysqld` se niega a hacer bootstrap para no perder transacciones. En ese caso:
respalda los tres volúmenes, ejecuta `wsrep-recover` en cada nodo y arranca solo
el nodo con la secuencia recuperada más alta. Después inicia los pares y confirma
que los tres estén saludables y sincronizados. Si las posiciones difieren, detén
la recuperación y conserva los respaldos. No borres volúmenes ni fuerces el
bootstrap sin verificar la posición.
