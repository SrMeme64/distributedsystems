# Pendientes de mejora del sistema distribuido

El stack actual es una demostración en un solo host. Las siguientes tareas
describen cómo evolucionarlo; no deben confundirse con componentes ya
desplegados.

## 1. Probar desde dos equipos y aclarar el acceso

- [ ] Ejecutar Compose en el equipo anfitrión y las PoC HTTP desde el equipo
  cliente usando la IP LAN del anfitrión, no `localhost`.
- [ ] Permitir TCP/80 en el firewall solo para la red de pruebas y mantener
  Nagios restringido al equipo anfitrión o administración.
- [ ] Registrar IP del host, topología de red, herramienta, resultados y
  evidencias de cada prueba.
- [ ] Para probar failover de presentación desde la LAN, diseñar una VIP
  enrutable o usar un balanceador externo; la VIP Docker actual no cumple ese
  requisito.

## 2. Reducir dependencias de datos de instancia única

- [ ] Mover MongoDB a un servicio administrado o configurar un replica set
  operado correctamente.
- [ ] Mover Redis a un servicio administrado o configurar un modo apropiado de
  alta disponibilidad.
- [ ] Decidir si Redis es una caché descartable o si sus datos deben sobrevivir
  a fallas.
- [ ] Añadir monitoreo y planes de respaldo/restauración para MariaDB.
- [ ] Probar regularmente los procedimientos de restauración.

## 3. Mejorar el comportamiento de caché

- [ ] Definir claves y TTL para cada consulta almacenada en caché.
- [ ] Invalidar las entradas afectadas cuando cambien los datos del catálogo.
- [ ] Evitar estampidas de caché para que fallos simultáneos no consulten todos
  MariaDB a la vez.
- [ ] Mantener el endpoint de limpieza limitado a las claves de caché previstas.

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

- [ ] Crear un usuario de aplicación MongoDB con privilegios mínimos en vez de
  usar la cuenta root.
- [ ] Proteger Redis si puede alcanzarse fuera de una red privada confiable.
- [ ] Gestionar secretos fuera de archivos que se agregan al repositorio.
- [ ] Añadir TLS en la entrada pública.
- [ ] Añadir autenticación y límites de solicitudes a la API cuando corresponda.
- [ ] Adoptar migraciones de base de datos.
- [ ] Documentar procedimientos de operación y recuperación.

## Orden de implementación sugerido

1. Ejecutar las PoC desde dos equipos y registrar la configuración de red.
2. Mantener y documentar la conexión actual de la aplicación a Galera sin
  presentar failover SQL como una capacidad ya implementada.
3. Diseñar failover de la entrada de presentación si se requiere fuera del host.
4. Sustituir las instancias únicas de MongoDB y Redis por alternativas
   administradas o replicadas.
5. Mover las réplicas web y API a un orquestador multinodo y adoptar trazas
   distribuidas.
