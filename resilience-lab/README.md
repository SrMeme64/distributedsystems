# Laboratorio de rendimiento y resiliencia

El laboratorio acompaña al stack `distributed-three-tier`: ofrece un dashboard
para ejecutar pruebas HTTP y fallas controladas, conservar sus resultados y
consultar el informe HTML de JMeter. Los resultados validados para esta
ejecución están en [RESULTADOS-PRUEBAS.md](./RESULTADOS-PRUEBAS.md); el catálogo
de escenarios y criterios se encuentra en [TEST-PLAN.md](./TEST-PLAN.md).

## Inicio

Requisitos: Docker Desktop con Compose v2 y el stack principal iniciado. Desde
PowerShell, en la raíz del repositorio:

```powershell
docker compose --env-file .\.env.exam up -d --build
docker compose -f .\resilience-lab\docker-compose.yml up -d --build
Start-Process http://localhost:8090
```

El laboratorio se conecta a la red externa
`distributed-three-tier_edge` y usa `http://presentation-entry` como destino
predeterminado. Para otro nombre de proyecto, establece `TARGET_PROJECT` de
forma idéntica en los dos Compose. La URL inicial del dashboard se configura
con `DEFAULT_TARGET`; `DASHBOARD_PORT` cambia el puerto publicado (por defecto
8090).

El dashboard está pensado para uso local. No publiques el puerto ni el socket
de Docker en una red no confiable.

## Herramientas disponibles

| Herramienta | Contenedor | Parámetros principales | Uso |
|---|---|---|---|
| ApacheBench (`ab`) | `lab-ab` | URL, número de solicitudes, concurrencia, timeout y keep-alive. | Humo, carga de número fijo de solicitudes y percentiles. |
| Siege | `lab-siege` | URLs, usuarios simultáneos, duración, demora y modo benchmark. | Disponibilidad y caudal con carga durante un intervalo. |
| JMeter | `lab-jmeter` | URL base, rutas, hilos, rampa, duración y tiempo de espera. | Perfiles de usuarios y gráficas del informe HTML. |
| Chaos Monkey | `lab-chaosmonkey` | Grupo o servicios, acción, intervalo, duración de falla, duración total, máximo simultáneo, URL de sondeo y simulación. | Disponibilidad durante fallas seleccionadas de contenedores del proyecto. |

Cada herramienta tiene un script `run.sh`. El dashboard valida los parámetros,
ejecuta la herramienta en su contenedor, guarda consola y artefactos en el
volumen `results` y presenta las métricas que puede extraer. JMeter además
genera `results.jtl` y un informe HTML.

## Flujo recomendado

1. **Línea base:** ejecuta readiness del stack, pruebas unitarias y un perfil
   rápido de ApacheBench, Siege o JMeter.
2. **Carga:** compara caché fría y caliente y luego ejecuta una prueba sostenida
   de duración y concurrencia previamente definidas.
3. **Failover:** valida por separado las réplicas web/API, balanceadores,
   Galera/ProxySQL, MongoDB y Redis/Sentinel. Espera la recuperación completa
   entre escenarios.
4. **Caos:** comienza con Chaos Monkey en simulación (`DRY_RUN`). Si se autoriza
   una inyección real, selecciona un grupo concreto, una víctima simultánea,
   una ventana corta y una URL de salud.
5. **Resultado:** compara solicitudes correctas, errores, percentiles,
   disponibilidad, trazas y consumo de recursos; guarda la salida y anota
   parámetros y fecha en el informe.

Las guías de carga desde una segunda laptop y de las tres PoC están en
[`../PoCs/README.md`](../PoCs/README.md). Este dashboard es la vía para los
escenarios adicionales de rendimiento y caos; no reemplaza las pruebas de
readiness ni los checks funcionales del plan.

## Grupos de Chaos Monkey

El panel permite dirigir las fallas a estos grupos: `web`, `app`,
`presentation-lb`, `application-lb`, `galera`, `proxysql`, `mongodb`, `redis`,
`redis-data` y `redis-sentinel`. También se pueden especificar servicios
concretos. Las acciones configurables son detener, terminar o pausar.

Por defecto, Chaos Monkey mide `/api/health`, pero es posible elegir otra URL.
Cada sondeo registra estado, latencia y errores. La salida contiene eventos y
un resumen JSON con fallas inyectadas, sondeos, disponibilidad y duración de
la interrupción. Los contenedores protegidos —entre ellos `presentation-entry`
y los trabajos de inicialización— se excluyen del conjunto de víctimas. Al
terminar o cancelar, el script restaura los objetivos que dejó fuera de
servicio.

**La restauración automática no elimina el riesgo de una falla real.** Si un
experimento interrumpe una dependencia compartida, la recuperación puede tardar
más que el intervalo configurado. No selecciones `any`, `Intenso` ni varios
objetivos simultáneos para una primera prueba.

## Alcance del plan

El dashboard permite configurar las siguientes familias de casos:

- **Rendimiento:** humo, carga sostenida, estrés gradual dentro de límites,
  picos, resistencia, comparación de caché y mediciones por capa.
- **Alta disponibilidad:** balanceadores, web/API, Galera y ProxySQL, MongoDB,
  Redis y Sentinel, con verificación de failover y recuperación.
- **Caos:** fallas de contenedor y pruebas combinadas con carga. La inyección
  de red, las fallas de tiempo, la presión de disco y la recuperación de todo
  el stack requieren preparación adicional y no son botones de este dashboard.
- **Observabilidad:** Nagios, logs, `/api/health`, `X-Request-Trace`, tiempo de
  detección y tiempo de recuperación.

La presencia de una herramienta o una opción no significa que ese escenario se
haya ejecutado. El estado y las métricas comprobadas están en el
[informe de resultados](./RESULTADOS-PRUEBAS.md).

## Seguridad y cuidado de datos

- El dashboard y Chaos Monkey montan `/var/run/docker.sock`; quien controle
  estos contenedores puede controlar el daemon Docker. Usa el laboratorio solo
  en un host de confianza.
- Mantén límites de duración y concurrencia acordes con los recursos del host.
  No ejecutes una prueba de saturación, disco lleno o partición de Galera sin
  autorización, plan de recuperación y respaldo verificado.
- Evita detener el quórum de Galera o intervenir simultáneamente más nodos de
  los que el escenario permite.
- Los resultados persisten en el volumen `results`. `docker compose down -v`
  elimina ese historial y también puede borrar volúmenes del stack si se usa
  con el Compose principal; no lo uses como método de limpieza rutinario.

## Detener el laboratorio

Desde la raíz del repositorio:

```powershell
docker compose -f .\resilience-lab\docker-compose.yml stop
```

Este comando detiene las herramientas sin eliminar el volumen de resultados.

## Evidencia visual

![Dashboard del laboratorio de resiliencia](./panel-laboratorio.png)
