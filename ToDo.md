# ToDo: mejoras de la capa de datos

## Solicitado por el docente (7 puntos)

| # | Mejora | Estado |
|---|---|---|
| 1 | MongoDB replica set / gestionado | ✅ `rs0` de 3 nodos; failover de primario validado |
| 2 | Redis HA / gestionado | ✅ Maestro + 2 réplicas + 3 centinelas; failover validado |
| 3 | Redis descartable o persistente | ✅ Descartable: sin AOF/RDB; catálogo se reconstruye desde MariaDB |
| 4 | Eliminar conexión directa a `galera1` | ✅ API usa `DB_HOST=proxysql` |
| 5 | Proxy DB-aware | ✅ ProxySQL 2.6 con hostgroups Galera y monitoreo de `wsrep` |
| 6 | Enrutamiento lectura/escritura en Galera | ✅ `SELECT` → hostgroup 30, escrituras → hostgroup 10 |
| 7 | Límites del pool al escalar réplicas | ✅ `DB_POOL_SIZE` por API, límites documentados |

## Adiciones (fuera de la solicitud original)

Mejoras de resiliencia y operación implementadas durante la ejecución:

- Sentinel monitorea la IP fija `172.32.0.11` para evitar `TILT` cuando Docker elimina el DNS del maestro detenido.
- `REDIS_COMMAND_TIMEOUT_MS` (2 s): cada comando de caché tiene límite; si Redis no responde, el catálogo se lee de MariaDB.
- Fallback del catálogo a MariaDB cuando Redis no está disponible; `POST /api/cache/clear` devuelve `503`.
- `timeout check 4s` en HAProxy para que un Redis lento no marque caídos los tres backends API.
- La API arranca aunque MongoDB no esté disponible (conexión en segundo plano) y se reconecta automáticamente cuando el replica set vuelve.
- `galera/entrypoint.sh`: detecta datos con `safe_to_bootstrap=0` y une `galera1` al clúster en lugar de negarse a arrancar.
- `db-bootstrap` cicla `galera1,galera2,galera3` y reintenta `EAI_AGAIN`/`ENOTFOUND`.
- Nagios con 23 hosts (proxysql, mongo1/2/3, redis-master/replica/sentinel).
- Chaos Monkey con grupos `proxysql`, `mongodb`, `redis-data`, `redis-sentinel`; dashboard actualizado.
- PoC 1, 2 y 3 recreadas y documentadas con resultados en el README.

## Recuperación de Galera (si todos los nodos caen)

Si ningún nodo tiene `safe_to_bootstrap=1`, `mysqld` se niega a hacer bootstrap
para no perder transacciones. Respaldar los tres volúmenes, ejecutar
`wsrep-recover` en cada nodo y arrancar solo el nodo con la secuencia recuperada
más alta. Después iniciar los pares y confirmar que los tres estén saludables y
sincronizados. No borrar volúmenes ni forzar bootstrap sin verificar la posición.
