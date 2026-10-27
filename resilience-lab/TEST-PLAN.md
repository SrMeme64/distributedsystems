# Plan de pruebas del sistema distribuido

Este plan define cómo comprobar la línea base, el rendimiento, la alta
disponibilidad, la resiliencia ante fallas y la observabilidad del sistema
`distributed-three-tier`. Javier y Adriana lo organizamos siguiendo las
indicaciones del docente para validar el comportamiento funcional y distribuido
del proyecto.

El plan describe los escenarios y sus criterios esperados; no constituye por
sí mismo evidencia de ejecución. Los resultados medidos, el alcance ejecutado
y las limitaciones se encuentran en
[RESULTADOS-PRUEBAS.md](./RESULTADOS-PRUEBAS.md). La guía de herramientas y
operación está en [README.md](./README.md).

## Preparación común

1. Iniciar el stack principal y confirmar que las dependencias están
   saludables.
2. Ejecutar las comprobaciones de readiness y las pruebas unitarias antes de
   inyectar fallas.
3. Registrar la hora, parámetros, carga, estado HTTP, latencia, tasa de error,
   traza `X-Request-Trace` y consumo de recursos.
4. Después de cada inyección, restaurar el componente y confirmar que la salud
   y la topología vuelven al estado inicial.
5. Si el escenario detiene servicios, ejecutar uno a la vez y verificar el
   retorno antes de comenzar el siguiente.

Herramientas disponibles en el repositorio: `PoCs/Test-StackHealth.ps1`,
`PoCs/Invoke-LoadTest.ps1`, `PoCs/Monitor-LanHealth.ps1`,
`PoCs/Test-LanFailover.ps1`, `PoCs/Invoke-ChaosTest.ps1` y el dashboard de
`resilience-lab/` con ApacheBench, Siege, JMeter y Chaos Monkey. Los comandos
se detallan en [README principal](../README.md) y
[guía del laboratorio](./README.md).

## 1. Línea base y comprobaciones funcionales

Ejecutar estas comprobaciones antes de introducir fallas:

- **Salud de servicios:** comprobar que las réplicas previstas están activas,
  HAProxy muestra los backends disponibles y `/api/health` devuelve HTTP 200
  con estado `ok`.
- **Estado de datos:** confirmar Galera con tres miembros `Primary` y
  `Synced`; MongoDB `rs0` con un `PRIMARY` y dos `SECONDARY`; Redis con maestro,
  réplicas y Sentinel disponibles.
- **ProxySQL:** comprobar que el hostgroup 10 tiene un writer activo y que los
  grupos de lectura reflejan los nodos sincronizados disponibles.
- **Distribución de solicitudes:** observar `X-Request-Trace` para identificar
  el balanceador, el nodo web y el backend API; repetir solicitudes para
  comprobar el uso de las réplicas.
- **Consistencia:** insertar un dato de prueba en Galera, leerlo desde los
  demás nodos y retirarlo; verificar el ciclo de lectura y escritura de
  reseñas.
- **Caché:** comprobar aciertos, fallos y vaciado de Redis. Con Redis como
  única dependencia no disponible, el catálogo debe seguir accesible desde
  MariaDB y la salud informar degradación.
- **Readiness y regresión:** ejecutar `Test-StackHealth.ps1` y
  `npm --prefix .\application test`.

## 2. Pruebas de rendimiento

Empezar con perfiles de baja intensidad. Para cada ejecución registrar
solicitudes, usuarios/hilos, duración, demora, tasa de solicitudes, p50/p95/p99,
errores HTTP y CPU/memoria por contenedor.

| Escenario | Procedimiento | Criterio de observación |
|---|---|---|
| Humo | 1–5 usuarios o un conjunto pequeño de solicitudes con ApacheBench, Siege o JMeter. | Ruta funcional, sin errores inesperados. |
| Carga | Mantener el nivel esperado durante 10–30 minutos con Siege o JMeter. | Registrar disponibilidad, p95/p99 y recursos durante toda la ventana. |
| Estrés | Incrementar gradualmente concurrencia o solicitudes. | Identificar el primer aumento sostenido de latencia, errores o recursos; acordar límite antes de comenzar. |
| Pico | Aumentar de 5 a 300 usuarios en segundos con JMeter. | Medir impacto, convergencia y recuperación después del pico. |
| Resistencia prolongada | Mantener una carga moderada durante varias horas. | Observar fugas, reinicios, conexiones agotadas y degradación progresiva. |
| Efecto de caché | Comparar el catálogo con caché fría y caliente; vaciarla con `/api/cache/clear`. | Comparar tiempos, caudal y lecturas de base de datos. |
| Capacidad por capa | Medir web, aplicación y base de datos por separado, sin las capas superiores cuando sea posible. | Localizar el cuello de botella sin atribuir a una capa el costo de otra. |

ApacheBench mide un número fijo de solicitudes; Siege ejecuta usuarios durante
un tiempo definido; JMeter permite rampas, tiempos de espera y un informe HTML.
Las métricas son observaciones: los umbrales SLO deben definirse antes de una
validación formal, no asumirse a partir de una sola ejecución.

## 3. Alta disponibilidad y failover

Con tráfico de observación activo, introducir una falla por vez. Registrar el
tiempo de detección, pérdida de solicitudes, cambio de VIP o rol, y tiempo de
recuperación.

| Componente | Falla que se debe comprobar | Resultado esperado |
|---|---|---|
| Balanceador de presentación | Detener, terminar o pausar el master; congelar HAProxy con el contenedor activo; recuperar el master. | Keepalived transfiere la VIP al backup y realiza failback sin oscilación persistente. |
| Balanceador de aplicación | Repetir las fallas del balanceador de presentación para la VIP `172.31.0.250`. | El backup mantiene el acceso a los nodos API y la VIP vuelve al master al recuperarse. |
| Ambos balanceadores de una capa | Detener simultáneamente master y backup. | Se espera una interrupción del punto de entrada; restaurar ambos y confirmar recuperación. |
| Nodos web/API | Detener una réplica y luego dos de tres, por separado para cada capa. | HAProxy retira las réplicas caídas; la capacidad se reduce, pero el servicio permanece disponible mientras exista backend sano. |
| Writer Galera | Detener el nodo activo del hostgroup 10. | ProxySQL promueve otro writer; verificar lecturas, escritura de prueba y replicación. |
| Nodo Galera secundario | Detener o aislar `galera2` o `galera3` de forma individual. | Los dos nodos restantes conservan quórum; ProxySQL reclasifica el nodo y este se reincorpora. |
| `galera1` | Detener el nodo designado para bootstrap. | Comprobar que los nodos restantes sostienen el componente primario y conservan un writer utilizable. |
| ProxySQL | Detener y restaurar el proxy de base de datos. | Durante la falla el acceso de la API al catálogo puede responder 503; tras restaurarlo, recuperar salud y consultas. |
| MongoDB primario | Detener el primario actual (`mongo1` o el elegido en ese momento). | `rs0` elige otro primario y las reseñas vuelven a responder. |
| MongoDB secundario | Detener individualmente una réplica secundaria. | El replica set conserva primario; sin pérdida del servicio de reseñas. |
| Redis maestro | Detener el maestro identificado en tiempo de ejecución. | Sentinel promueve una réplica; el catálogo conserva respuesta y puede recurrir a MariaDB durante la transición. |
| Redis Sentinel | Detener dos de los tres centinelas. | Se pierde el quórum de failover; el maestro existente sigue atendiendo hasta su recuperación. |
| Redis completo | Detener maestro y réplicas. | `/api/health` informa degradación, el catálogo sigue disponible desde MariaDB y la operación de vaciado de caché puede fallar. |
| Proxy de entrada | Detener `presentation-entry`. | Se pierde el punto de entrada publicado; el alcance de ejecución en un único host no elimina este punto único de falla. |

Al finalizar cada caso, confirmar que los backends vuelvan a estar disponibles,
que las VIP y roles sean coherentes y que la traza de una nueva solicitud
atraviese el stack recuperado.

## 4. Ingeniería del caos

Cada experimento debe formular una hipótesis, limitar víctimas simultáneas,
definir duración y condición de parada, y restaurar los componentes al
finalizar. Medir disponibilidad y latencia mientras se inyecta la falla y
durante la recuperación.

- **Fallas de contenedor:** simular primero con `DRY_RUN`; después, si está
  autorizado, detener, terminar o pausar una réplica de un grupo objetivo.
  Chaos Monkey registra eventos, sondeos y resumen de disponibilidad.
- **Fallas de red:** añadir latencia, variación, pérdida o límites de ancho de
  banda en un enlace acotado y reversible. Las particiones de Galera requieren
  un plan específico de quórum y recuperación; no se deben improvisar.
- **Presión de recursos:** limitar CPU o memoria de un contenedor individual
  y observar degradación y recuperación. Una saturación del host, disco lleno
  o agotamiento de recursos globales no es una prueba de bajo impacto.
- **Fallas de tiempo:** los desfases de reloj pueden afectar elecciones y
  protocolos; requieren hosts o contenedores aislados y sincronización
  restaurable.
- **Dependencias lentas:** aumentar la latencia de base de datos o caché de
  forma acotada para observar timeouts, reintentos y respuesta degradada.
- **Fallos combinados:** ejecutar carga con una inyección de falla solo después
  de validar cada componente por separado y acordar concurrencia y duración.
- **Recuperación global:** detener y volver a iniciar el stack para comprobar
  dependencias de arranque, elección de primario, estado de Galera, VIP y salud.

El contenedor del dashboard y el de Chaos Monkey montan
`/var/run/docker.sock`, lo cual les otorga control del daemon Docker. Usar el
laboratorio solo en una máquina de confianza. Mantener el máximo de víctimas
en uno para empezar y excluir servicios de inicialización y el proxy de entrada
salvo que el escenario lo requiera expresamente.

## 5. Observabilidad y alertas

- Comprobar que Nagios detecta una falla dentro del intervalo de supervisión y
  que la recuperación devuelve el servicio al estado normal.
- Correlacionar estado HTTP, `/api/health`, `X-Request-Trace`, logs de HAProxy,
  Galera, MongoDB, Redis y los eventos del experimento.
- Registrar tiempo medio de detección, tiempo medio de recuperación, duración
  de interrupción, solicitudes fallidas y consumo de CPU/memoria.
- Diferenciar una alerta local registrada de una notificación entregada por
  correo. El transporte de correo debe probarse por separado y con autorización.

## Limitaciones de la arquitectura que deben considerarse

- `presentation-entry` es un único punto de entrada.
- ProxySQL y el host Docker no tienen una réplica externa en esta topología.
- Todos los contenedores se ejecutan en el mismo host; la pérdida del host o
  Docker Desktop interrumpe el sistema completo.
- Redis Sentinel usa direcciones fijas de la red de datos; al cambiar esa
  subred, revisar `redis/sentinel.conf` y `redis/redis-replica.conf`.
- `docker compose down` elimina contenedores; `docker compose down -v` elimina
  también los volúmenes de datos y resultados.
