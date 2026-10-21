# Pendientes de mejora del sistema distribuido

El stack actual es una demostración en un solo host. Las siguientes tareas
describen cómo evolucionarlo; no deben confundirse con componentes ya
desplegados. Para este proyecto académico, Compose permanece como el entorno
reproducible del host; la segunda laptop se usa como cliente de las PoC LAN.
No se declara alta disponibilidad multinodo ni se requiere contratar servicios
administrados.

## 1. Probar desde dos equipos y aclarar el acceso

- [ ] Ejecutar Compose en el equipo anfitrión y las PoC HTTP desde el equipo
  cliente usando la IP LAN del anfitrión, no `localhost`.
- [ ] Permitir TCP/80 en el firewall solo para la red de pruebas y mantener
  Nagios restringido al equipo anfitrión o administración.
- [ ] Registrar IP del host, topología de red, herramienta, resultados y
  evidencias de cada prueba.
- [ ] Probar desde el cliente LAN el failover de los HAProxy de presentación a
  través de `presentation-entry` y la VIP Docker `172.30.0.250`; registrar que
  `presentation-entry` y el host siguen siendo puntos únicos de falla.

## 2. Reducir dependencias de datos de instancia única

- [ ] Evaluar un replica set local para MongoDB si los recursos del host lo
  permiten; documentar que no protege contra la caída del host.
- [ ] Evaluar alta disponibilidad local para Redis solo si las PoC requieren
  conservar la caché ante la caída de un contenedor.
- [x] Definir Redis como caché descartable: los datos se pueden reconstruir
  desde MariaDB.
- [ ] Añadir monitoreo y planes de respaldo/restauración para MariaDB.
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
- [ ] Añadir TLS en la entrada pública.
- [ ] Añadir autenticación y límites de solicitudes a la API cuando corresponda.
- [ ] Adoptar migraciones de base de datos.
- [ ] Documentar procedimientos de operación y recuperación.

## Orden de implementación sugerido

1. Ejecutar las PoC desde dos equipos y registrar la configuración de red.
2. Añadir y probar respaldos/restauración de MariaDB en el host del proyecto.
3. Incorporar observabilidad local y registrar resultados de rendimiento y
   disponibilidad en las PoC.
4. Evaluar replica set de MongoDB o HA de Redis solo si el hardware disponible
   lo soporta; esto no resolvería la caída del host.
5. Dejar orquestación multinodo y failover entre hosts como evolución futura,
   sujeta a disponer de más hosts o infraestructura adicional.
