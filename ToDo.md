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
- [ ] Ejecutar las PoC HTTP desde la segunda laptop usando la IP LAN del
  anfitrión, no `localhost`; aún no se ha probado desde ese equipo.
- [ ] Confirmar desde la segunda laptop si TCP/80 está permitido por el
  firewall del host. La Wi-Fi del anfitrión usa perfil `Public` y no hay regla
  entrante explícita para TCP/80; no abrir el acceso ampliamente. Si la prueba
  se requiere, limitarlo a la IP/subred autorizada.
- [x] Restringir Nagios al host: Compose publica el puerto 8088 en
  `127.0.0.1`, no en las interfaces LAN.
- [ ] Registrar IP del host, topología de red, herramienta, resultados y
  evidencias de las pruebas desde el cliente.
- [x] Probar desde el host el failover de los HAProxy de presentación a través
  de `presentation-entry` y la VIP Docker `172.30.0.250`: al detener el master,
  la API respondió HTTP 200 por el backup.
- [ ] Repetir el failover desde el cliente LAN. En la prueba local, al iniciar
  de nuevo el contenedor master no recuperó la VIP automáticamente; fue
  necesario reiniciar `presentation-keepalived-master`. Registrar o resolver
  esta recuperación antes de considerar completa la PoC.
- [x] Confirmar que `presentation-entry` y el host siguen siendo puntos únicos
  de falla; el failover de los HAProxy no protege ante su caída.

## 2. Reducir dependencias de datos de instancia única

- [ ] Evaluar un replica set local para MongoDB si los recursos del host lo
  permiten; documentar que no protege contra la caída del host.
- [ ] Evaluar alta disponibilidad local para Redis solo si las PoC requieren
  conservar la caché ante la caída de un contenedor.
- [x] Definir Redis como caché descartable: los datos se pueden reconstruir
  desde MariaDB.
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
- [ ] Pendiente: repetir pruebas desde la segunda laptop y registrar su IP,
  conectividad LAN, reglas de firewall y evidencias. La ejecución local no
  confirma acceso desde otro equipo.

## Orden de implementación sugerido

1. Completar PoC desde la segunda laptop, incluyendo acceso LAN y failover;
   restringir TCP/80 a su IP o subred autorizada.
2. Automatizar respaldos periódicos de MariaDB y documentar monitoreo y
   retención; ya se comprobó una restauración manual en una base temporal.
3. Incorporar observabilidad local y registrar resultados de rendimiento y
   disponibilidad en las PoC.
4. Evaluar replica set de MongoDB o HA de Redis solo si el hardware disponible
   lo soporta; esto no resolvería la caída del host.
5. Dejar orquestación multinodo y failover entre hosts como evolución futura,
   sujeta a disponer de más hosts o infraestructura adicional.
