# Mejoras de la capa de datos (solicitadas)

Las 7 mejoras solicitadas están implementadas y verificadas. Todo lo demás se
descarta; este documento solo registra lo que se pidió.

## Estado

| # | Mejora solicitada | Implementado | Verificado |
|---|---|---|---|
| 1 | MongoDB replica set / gestionado | `rs0` de 3 nodos (`mongo1/2/3`) con keyfile, usuario `store_app` limitado | `mongo1=PRIMARY`, `mongo2/3=SECONDARY`; failover de primario validado |
| 2 | Redis HA / gestionado | Maestro + 2 réplicas + 3 centinelas (quórum 2) | Sentinel promovió réplica al detener el maestro; health degradó y recuperó |
| 3 | Redis descartable o persistente | Descartable: sin AOF ni RDB; catálogo se reconstruye desde MariaDB | Caída total de Redis: health `degraded`, catálogo 200 desde MariaDB, cache clear 503 |
| 4 | Eliminar conexión directa a `galera1` | API usa `DB_HOST=proxysql` (puerto 6033) | ProxySQL enruta escrituras al hostgroup 10 y lecturas al 30 |
| 5 | Proxy DB-aware | ProxySQL 2.6 con `mysql_galera_hostgroups` y monitoreo de `wsrep` | Failover de writer validado: `galera2` promovido al detener `galera3` |
| 6 | Enrutamiento lectura/escritura en Galera | `SELECT ... FOR UPDATE` y escrituras → hostgroup 10; `SELECT` → hostgroup 30 | Verificado con `stats_mysql_query_digest` |
| 7 | Límites del pool al escalar réplicas | `DB_POOL_SIZE` por API, `3 × DB_POOL_SIZE` total, límites ProxySQL/Galera documentados | 3 réplicas × 10 = 30 conexiones, por debajo de `max_connections=200/30` |

## Verificación final (23-10-2026)

- `docker compose --env-file .env.exam up -d` → código 0.
- `/api/health` → `200 {"status":"ok","mariadb":"ok","mongodb":"ok","redis":"ok"}`.
- Catálogo → 200; reseñas → 200.
- Galera: `wsrep_cluster_size=3`, `Primary`, `Synced`.
- Mongo: `mongo1=PRIMARY`, `mongo2/3=SECONDARY`.
- Redis: Sentinel maestro `172.32.0.11` con 2 réplicas.
- ProxySQL: SELECT → hostgroup 30; INSERT/DDL → hostgroup 10.
- 11 tests unitarios pasan (`node --test`).
- Nagios: 23 hosts, 0 errores.

## Recuperación de Galera (si todos los nodos caen)

Si ningún nodo tiene `safe_to_bootstrap=1`, `mysqld` se niega a hacer bootstrap
para no perder transacciones. Respaldar los tres volúmenes, ejecutar
`wsrep-recover` en cada nodo y arrancar solo el nodo con la secuencia recuperada
más alta. Después iniciar los pares y confirmar que los tres estén saludables y
sincronizados. No borrar volúmenes ni forzar bootstrap sin verificar la posición.
