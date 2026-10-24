# Pendientes de mejora del sistema distribuido

El stack actual es una demostración en un solo host. Las siguientes tareas
describen cómo evolucionarlo; no deben confundirse con componentes ya
desplegados. Para este proyecto académico, Compose permanece como el entorno
reproducible del host; la segunda laptop se usa como cliente de las PoC LAN.
No se declara alta disponibilidad multinodo ni se requiere contratar servicios
administrados.

## 1. Probar desde dos equipos y aclarar el acceso

- [x] Levantar Compose en la laptop anfitriona con `.env.exam` y comprobar
  localmente salud, catálogo, reseñas y caché.
- [x] Probar desde la segunda laptop usando la IP LAN del anfitrión:
  `Test-NetConnection 192.168.1.69 -Port 80` tuvo éxito y
  `/api/health` respondió HTTP 200 desde el cliente `192.168.1.68`.
- [x] Permitir TCP/80 en el firewall solo desde `192.168.1.68`, hacia la IP
  local `192.168.1.69` y por la interfaz Wi-Fi. Aunque Windows clasifica esa
  interfaz como `Public`, no se abrió el puerto a otros equipos ni se cambió
  el perfil de red.
- [x] Restringir Nagios al host: Compose publica el puerto 8088 en
  `127.0.0.1`, no en las interfaces LAN.
- [x] Registrar para la prueba básica host `192.168.1.69` por Wi-Fi, cliente
  `192.168.1.68`, `Test-NetConnection` exitoso y `/api/health` HTTP 200.
- [x] Probar desde el host el failover de los HAProxy de presentación a través
  de `presentation-entry` y la VIP Docker `172.30.0.250`: al pausar el master,
  la API respondió HTTP 200 por el backup.
- [x] Verificar localmente failover y failback de las capas de presentación y
  aplicación después de corregir el arranque de los sidecars Keepalived.
- [x] Repetir failover y failback desde el cliente LAN `192.168.1.68` hacia el
  host `192.168.1.69`: ambas trazas cambiaron al balanceador backup y luego
  regresaron al master.
- [x] Guardar scripts reutilizables y evidencia de esta corrida en
  [poc/2026-10-22-lan-failover](./poc/2026-10-22-lan-failover/README.md),
  separados de futuras PoC.
- [x] Validar sintaxis de los scripts PowerShell; el monitor devolvió HTTP 200,
  el failover se revisó con `-WhatIf`, y las operaciones de firewall se
  comprobaron con `-WhatIf`/verificación de alcance sin quitar la regla activa.
- [x] Confirmar que `presentation-entry` y el host siguen siendo puntos únicos
  de falla; el failover de los HAProxy no protege ante su caída.

## 2. Reducir dependencias de datos de instancia única

- [x] Implementar un replica set local de MongoDB (`rs0`) con tres nodos,
  keyfile compartido y usuario de aplicación limitado; documentar que no
  protege contra la caída del host.
- [x] Implementar alta disponibilidad local para Redis con un maestro, dos
  réplicas y tres centinelas (quórum 2).
- [x] Definir Redis como caché descartable: sin AOF ni RDB, los datos se
  reconstruyen desde MariaDB.
- [x] Eliminar la conexión directa de la API a `galera1`: la API usa
  `DB_HOST=proxysql` y ProxySQL descubre al writer.
- [x] Enrutar lecturas y escrituras en Galera: `SELECT ... FOR UPDATE` y las
  escrituras al hostgroup 10; los `SELECT` simples al hostgroup 30.
- [x] Revisar los límites del pool al escalar réplicas: `DB_POOL_SIZE` por API,
  `3 × DB_POOL_SIZE` conexiones totales, límites de ProxySQL y MariaDB
  documentados en el README.
- [ ] Añadir monitoreo y una política de respaldos periódicos para MariaDB.
- [ ] Probar regularmente los procedimientos de restauración.

## 3. Mejorar el comportamiento de caché

- [x] Definir una clave y un TTL configurable para la consulta de productos
  más baratos.
- [ ] Invalidar las entradas afectadas cuando cambien los datos del catálogo
  (pendiente: el catálogo no tiene endpoints de escritura).
- [x] Evitar estampidas de caché entre réplicas de API mediante un bloqueo
  distribuido en Redis.
- [x] Mantener el endpoint de limpieza limitado a la única clave de caché del
  catálogo.

## 4. Añadir observabilidad

- [ ] Instrumentar presentación, API y llamadas a base de datos con OpenTelemetry.
- [ ] Centralizar logs, métricas y trazas.
- [ ] Añadir tableros y alertas para latencia, errores, saturación de recursos,
  salud de bases de datos y tasa de aciertos de caché.
- [ ] Reemplazar los encabezados y la UI de traza propios por trazas distribuidas
  con tiempos y spans entre servicios.
- [ ] Revisar la UI de trazas y cableado en [catalog.js](./web/catalog.js),
  [index.js](./application/index.js) y [docker-compose.yml](./docker-compose.yml).

## 5. Reforzar seguridad y operación

- [x] Documentar el arranque del Compose principal con el archivo `.env.exam`
  usando `--env-file`; guardar credenciales reales en `.env.local`, ignorado
  por Git.
- [x] Crear un usuario de aplicación MongoDB limitado a la base de reseñas en
  vez de usar la cuenta root desde la API.
- [x] Mantener Redis en la red interna de datos, sin publicar su puerto al host.
- [x] Restringir Nagios a `127.0.0.1:8088`; respondió localmente (HTTP 401 sin
  autenticación, HTTP 200 con la credencial configurada) y la IP LAN
  `10.20.0.168:8088` rechazó la conexión.
- [x] Documentar cómo reiniciar el sidecar Keepalived después de `stop/start`
  manual de un HAProxy.
- [x] Corregir el arranque de Keepalived: el Dockerfile limpiaba PID files en
  rutas equivocadas. Los sidecars ahora eliminan los archivos bajo
  `/run/keepalived/`; se reconstruyeron y los cuatro permanecieron activos sin
  reinicios.
- [ ] Añadir TLS en la entrada pública.
- [ ] Añadir autenticación y límites de solicitudes a la API cuando corresponda.
- [ ] Adoptar migraciones de base de datos.
- [ ] Documentar procedimientos de operación y recuperación.

## Verificación ejecutada el 21-10-2026

- [x] `docker compose --env-file .env.exam config --quiet` finalizó sin errores
  y `docker compose --env-file .env.exam up --build -d` levantó el stack.
- [x] `catalog-init` terminó con código 0 e inicializó el esquema MariaDB,
  el usuario de aplicación MongoDB y los datos de ejemplo.
- [x] `GET /api/health` respondió HTTP 200; catálogo (`/api/products/cheapest`)
  y reseñas de `ST-001` también respondieron HTTP 200.
- [x] Tras limpiar caché, la consulta de catálogo registró `cache miss`,
  consultó Galera y escribió en Redis; la siguiente registró `cache hit`.
  Devolvió 10 productos.
- [x] La cuenta MongoDB de la API tiene el rol `readWrite` únicamente en
  `store_reviews`; el usuario root se reserva para `catalog-init`.
- [x] Galera informó `wsrep_cluster_size=3` y estado `Synced`; los tres nodos
  quedaron saludables.
- [x] Pasaron las 4 pruebas unitarias de caché: hit, miss con TTL, concurrencia
  con una sola carga y liberación del bloqueo tras un error.
- [x] Probar failover y failback automáticos de presentación y aplicación:
  al pausar el HAProxy master, el backup devolvió HTTP 200; al reanudar el
  master, recuperó la VIP y el tráfico.
- [x] Verificar los cuatro chequeos HTTP de Keepalived (master y backup de
  presentación y aplicación): todos devolvieron éxito con sus balanceadores
  disponibles.
- [x] Identificar la causa de la recuperación manual tras `stop/start`: Docker
  recrea el namespace de red del HAProxy y el sidecar Keepalived queda asociado
  al namespace anterior, entra en `FAULT` y requiere reinicio. El README incluye
  los comandos de recuperación; para la PoC controlada se validó `pause/unpause`.
- [x] Pausar `app1` y `web1` por separado: cada capa siguió devolviendo HTTP
  200, se hicieron 12 solicitudes adicionales por nodos alternos y las
  réplicas volvieron a recibir tráfico después de reanudarlas.
- [x] Prueba local de concurrencia: 30 solicitudes simultáneas tras limpiar
  Redis dieron 30 respuestas válidas, una sola lectura de catálogo (cache miss)
  y 29 cache hits.
- [x] Carga local con caché caliente: 100 solicitudes al catálogo, concurrencia
  20, 0 errores; p50 43.6 ms, p95 166.0 ms y máximo 328.4 ms. Es una medición
  de esta laptop, no sustituye la PoC desde el segundo equipo ni define un SLO.
- [x] Crear un dump temporal de `store.products`, restaurarlo en una base
  temporal y comparar filas y suma de precios: coincidieron (12 filas,
  `177.16`). Se eliminó la base temporal; el procedimiento periódico y su
  monitoreo siguen pendientes.
- [x] Acceder desde la propia laptop a `http://10.20.0.168/api/health` dio
  HTTP 200. Esto verifica la ruta local del host, no sustituye la prueba desde
  otra laptop.
- [x] Corregir el chequeo de Keepalived para exigir respuesta HTTP 200; las
  pruebas de failover confirmaron que detecta HAProxy pausados.

## Verificación ejecutada el 22-10-2026

- [x] Investigar `curl.exe -i http://localhost/api/health` con `Empty reply`:
  los servicios de datos y aplicación estaban detenidos y Keepalived no podía
  mantener sus sidecars activos.
- [x] Crear y validar respaldos comprimidos de los tres volúmenes Galera antes
  de recuperar; se conservaron fuera del repositorio y no se eliminaron datos.
- [x] Ejecutar `wsrep-recover` únicamente sobre copias temporales: los tres
  nodos recuperaron el mismo UUID y posición `:30`. Se marcó `galera1` como
  seguro para bootstrap; los nodos 2 y 3 se sincronizaron por transferencia de
  estado.
- [x] Confirmar Galera con `wsrep_cluster_size=3`,
  `wsrep_cluster_status=Primary` y estado local `Synced`.
- [x] Corregir las rutas de PID de Keepalived, reconstruir los cuatro
  sidecars y comprobar que siguen activos con cero reinicios.
- [x] Después de la recuperación, la página, `/api/health` y
  `/api/products/cheapest` respondieron HTTP 200 localmente.
- [x] Probar localmente la VIP de presentación: el backup atendió
  `/api/health` con HTTP 200 al pausar el master; al reanudarlo, el master
  recuperó el tráfico.
- [x] Probar localmente la VIP de aplicación: el backup atendió
  `/api/health` con HTTP 200 al pausar el master y el master recuperó el
  tráfico al reanudarse.
- [x] Desde la laptop cliente `192.168.1.68`, verificar
  `Test-NetConnection 192.168.1.69 -Port 80` (`TcpTestSucceeded: True`) y
  `GET http://192.168.1.69/api/health` (HTTP 200).
- [x] Crear y verificar una regla de firewall limitada a TCP/80, cliente
  `192.168.1.68`, dirección local `192.168.1.69` e interfaz `Wi-Fi`. La
  solicitud HTTP se confirmó desde el segundo equipo.
- [x] Ejecutar desde el cliente una secuencia de 60 consultas al health durante
  el failover de presentación: la traza pasó de
  `presentation-lb-master` a `presentation-lb-backup` y volvió al master.
  Durante el cambio se observaron dos timeouts; una vez en backup, las
  solicitudes respondieron HTTP 200.
- [x] Repetir la secuencia durante el failover de aplicación: la traza pasó de
  `application-lb-master` a `application-lb-backup` y volvió al master.
  También se observaron dos timeouts durante la convergencia y HTTP 200 cuando
  cada nodo quedó activo.
- [x] Confirmar desde el host las respuestas HTTP 200 por los backups durante
  cada pausa y el retorno de HTTP 200 al reanudar cada master.

## Verificación ejecutada el 23-10-2026

- [x] `docker compose --env-file .env.exam config --quiet` finalizó sin errores.
- [x] El stack levantó con ProxySQL, `rs0` y Redis Sentinel; `db-bootstrap`,
  `mongo-init` y `catalog-init` terminaron con código 0.
- [x] `/api/health` respondió 200 con `mariadb`, `mongodb` y `redis` en `ok`;
  catálogo y reseñas respondieron 200.
- [x] `rs0` quedó con `mongo1` primario y `mongo2`/`mongo3` secundarios.
- [x] Sentinel reportó `mymaster` y dos réplicas.
- [x] ProxySQL enrutó los `SELECT` al hostgroup 30 y el DDL/INSERT al hostgroup
  10.
- [x] Failover de writer Galera: al detener `galera3`, ProxySQL promovió
  `galera2`; una escritura de prueba insertó 1 fila y el catálogo siguió en 200.
  Al reiniciar, `galera3` volvió como writer y el clúster quedó
  `wsrep_cluster_size=3`, `Synced`, `Primary`.
- [x] Failover de MongoDB: al detener `mongo1`, `mongo2` fue elegido primario;
  `GET` de reseñas respondió 200 y `POST` respondió 201. Al reiniciar, `mongo1`
  volvió como primario.
- [x] Failover de Redis: al detener el maestro actual, Sentinel promovió una
  réplica; `/api/health` respondió 200 y el catálogo 200 con
  `redis (unavailable) -> mariadb`; al reiniciar, el nodo volvió como réplica.
- [x] Caída total de Redis: `/api/health` respondió 200 `degraded` y el catálogo
  200 desde MariaDB; `POST /api/cache/clear` respondió 503. Tras reiniciar los
  seis contenedores, la salud volvió a `ok`.
- [x] Corregir el `TILT` de Sentinel: Docker elimina el DNS de un contenedor
  detenido y Sentinel no podía resolver `redis-master`; los centinelas
  monitorean la IP fija `172.32.0.11`.
- [x] Añadir `REDIS_COMMAND_TIMEOUT_MS` para que una caché que no responde no
  bloquee el catálogo; las lecturas degradan a MariaDB.
- [x] Ampliar el chequeo de HAProxy a `timeout check 4s` y acortar los chequeos
  de salud para que un fallo de Redis no marque los tres backends API como
  caídos.
- [x] Confirmar que `docker compose up -d` devuelve código 0; el código 1
  observado antes era un artefacto de las tuberías de PowerShell, no un fallo de
  Compose.
- [x] Retirar los contenedores huérfanos de intentos previos con
  `--remove-orphans`.
- [x] Recuperar `galera1` tras detenerlo solo: `galera/entrypoint.sh` detecta
  datos con `safe_to_bootstrap=0` y se une al clúster en lugar de intentar un
  bootstrap inseguro.
- [x] Ampliar los reintentos de `db-bootstrap` a `EAI_AGAIN`/`ENOTFOUND` y
  ciclar `galera1,galera2,galera3`; con `galera1` detenido, el bootstrap creó el
  usuario de monitoreo en `galera2`.
- [x] Verificar que la API arranca con MongoDB no disponible y se recupera sin
  reiniciar cuando el replica set vuelve.

## Orden de implementación sugerido

1. Automatizar respaldos periódicos de MariaDB y documentar monitoreo y
   retención; ya se comprobó una restauración manual en una base temporal.
2. Analizar y, si el alcance lo requiere, reducir los dos timeouts observados
   durante cada failover LAN; el backup asumió tráfico y ambos masters
   recuperaron el servicio.
3. Incorporar observabilidad local y registrar resultados de rendimiento y
   disponibilidad en las PoC.
4. Automatizar las pruebas de failover de ProxySQL, MongoDB y Redis para que
   puedan repetirse con un script y comparar tiempos de detección y recuperación.
5. Dejar orquestación multinodo y failover entre hosts como evolución futura,
   sujeta a disponer de más hosts o infraestructura adicional.
