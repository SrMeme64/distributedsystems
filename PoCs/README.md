# PoC LAN: carga, failover por capas y caos

Scripts para ejecutar las tres PoC del proyecto desde una laptop externa
(**cliente**) contra el host Docker. Todas las pruebas son **cliente → host**:

- el **cliente** genera las solicitudes HTTP y captura los resultados;
- el **host** ejecuta el script que provoca la falla y la restaura.

El cliente no ejecuta Docker y el host no genera la carga. Los resultados de la
última ejecución están documentados en el
[`README.md`](../README.md#resultados-principales) y las capturas se guardan en
[`evidencias/`](evidencias/), excluida de Git salvo su propio README.

| PoC | Resultado |
|---|---|
| 1. Carga | 500 solicitudes, concurrencia 20: **457.25 req/s**, 0 errores |
| 2. Failover por capas | **3/3 PASS**; 115/120 sondeos `200` (**95.8 %**) |
| 3. Caos | **69/70 sondeos `200`** (**98.6 %**), nodo restaurado |

La descripción completa de cada PoC y sus resultados están en el
[`README.md`](../README.md#cómo-se-ejecutan-las-poc).

## Topología

- **Host Docker:** ejecuta `docker compose --env-file .env.exam up -d`. Publica
  el puerto 80 y es el único que detiene, pausa o reanuda contenedores.
- **Cliente LAN:** segunda laptop con Windows, PowerShell 5.1 o superior,
  `curl.exe` y una copia del repositorio. Solo envía tráfico HTTP.
- **Nagios:** queda enlazado a `127.0.0.1:8088`; no forma parte de las PoC LAN.

Las IP cambian entre sesiones. Obtén la del host con:

```powershell
ipconfig | findstr /i "IPv4"
```

y usa esa dirección en lugar de `<IP_HOST>` en todos los comandos.

## Firewall del host

Docker publica el puerto 80 en `0.0.0.0`, así que el tráfico de la LAN llega al
contenedor. **Solo hace falta una regla si Windows bloquea la entrada** (por
ejemplo, con la interfaz clasificada como `Public`).

Comprueba primero desde el cliente:

```powershell
Test-NetConnection <IP_HOST> -Port 80
curl.exe -i http://<IP_HOST>/api/health
```

- `TcpTestSucceeded: True` y `HTTP/1.1 200 OK`: no toques el firewall.
- `TcpTestSucceeded: False`: en el host, con PowerShell **como administrador**:

  ```powershell
  .\PoCs\Enable-LanPocFirewall.ps1 `
    -HostIPv4 "<IP_HOST>" `
    -ClientIPv4 "<IP_CLIENTE>" `
    -InterfaceAlias "Wi-Fi" `
    -AllowPublicProfile
  ```

`-AllowPublicProfile` solo es necesario si la interfaz está en perfil `Public`;
no cambia el perfil ni abre el puerto a toda la red. El script es idempotente:
si cambian las IP, actualiza la regla existente `Distributed Store LAN PoC
(TCP 80)` en lugar de duplicarla.

Para retirarla cuando termines las pruebas:

```powershell
.\PoCs\Remove-LanPocFirewall.ps1 `
  -HostIPv4 "<IP_HOST>" `
  -ClientIPv4 "<IP_CLIENTE>" `
  -InterfaceAlias "Wi-Fi"
```

Ambos scripts aceptan `-WhatIf` para revisar la acción sin aplicarla.

## Antes de empezar

En el **host**, confirma que el stack está listo:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Test-StackHealth.ps1
```

Debe terminar con `Resultado: LISTO para la demo (9 comprobaciones)`. Si no,
ejecuta `.\Start-Stack.ps1` y repite.

En el **cliente**, confirma la ruta:

```powershell
Test-NetConnection <IP_HOST> -Port 80
curl.exe -i http://<IP_HOST>/api/health
```

Abre dos terminales: una en el cliente y otra en el host.

## PoC 1: carga desde el cliente

Mide latencia y throughput del catálogo con caché fría y caliente.

**En el host**, vacía la caché:

```powershell
curl.exe -sS -o NUL -w "cache_clear HTTP %{http_code}`n" -X POST http://localhost/api/cache/clear
```

**En el cliente**, mide:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Invoke-LoadTest.ps1 `
  -BaseUrl "http://<IP_HOST>" -Requests 1 -Concurrency 1

powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Invoke-LoadTest.ps1 `
  -BaseUrl "http://<IP_HOST>" -Requests 500 -Concurrency 20
```

Opcional, para ver el punto de saturación: repite la carga caliente con
`-Concurrency 10` y `-Concurrency 50`. No hace falta instalar `ab`.

### Qué capturar

| Escenario | Solicitudes | Concurrencia | Fallidas | Req/s | Tiempo medio | p95 |
|---|---|---|---|---|---|---|
| Caché fría | 1 | 1 | | | | |
| Caché caliente | 500 | 20 | | | | |
| Caché caliente (opcional) | 500 | 50 | | | | |

Guarda la salida completa en `PoCs/evidencias/poc1-carga-<fecha>.txt`.

## PoC 2: failover por capas

Comprueba, desde el cliente, que el sistema sigue respondiendo cuando falla un
nodo API o el HAProxy master de presentación o de aplicación. Las tres fases se
ejecutan **en orden con un solo script** en el host.

**En el cliente**, inicia el monitor (120 sondeos cada 500 ms, ~60 s):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Monitor-LanHealth.ps1 `
  -HostIPv4 "<IP_HOST>" -RequestCount 120 -IntervalMilliseconds 500
```

**En el host**, mientras el monitor imprime líneas:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Test-LanFailover.ps1 `
  -Layer All -HoldSeconds 12
```

| Fase | Qué hace el host | Qué debe verse en la traza del cliente |
|---|---|---|
| 1. API | detiene `app1` durante `HoldSeconds` y lo restaura | `app1` desaparece; responden `app2`/`app3` |
| 2. Presentación | **pausa** `presentation-lb-master` y lo reanuda | `presentation-lb-backup` y luego vuelve el master |
| 3. Aplicación | **pausa** `application-lb-master` y lo reanuda | `application-lb-backup` y luego vuelve el master |

Los HAProxy se **pausan**, no se detienen: el sidecar Keepalived comparte su
*network namespace* y pausar conserva ese namespace para que el VIP migre al
backup. Cada fase restaura lo que cambió en un bloque `finally`, incluso con
`Ctrl+C`.

Para probar una sola capa:

```powershell
.\PoCs\Test-LanFailover.ps1 -Layer Api
.\PoCs\Test-LanFailover.ps1 -Layer Presentation
.\PoCs\Test-LanFailover.ps1 -Layer Application
```

Para revisar sin tocar nada: añade `-WhatIf`.

### Qué capturar

| Fase | Traza antes | Cambio observado | Tiempo de failover | Vuelta al master | HTTP 200 / errores |
|---|---|---|---|---|---|
| API (`app1`) | | | | | |
| Presentación | | | | | |
| Aplicación | | | | | |

Guarda la salida del monitor en
`PoCs/evidencias/poc2-failover-cliente-<fecha>.txt` y el resumen del host en
`PoCs/evidencias/poc2-failover-host-<fecha>.txt`.

## PoC 3: Chaos Engineering

Inyecta una falla aleatoria en una réplica API durante 15 s y mide la
disponibilidad desde el cliente.

**En el cliente**, inicia el monitor (70 sondeos cada 500 ms, ~35 s):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Monitor-LanHealth.ps1 `
  -HostIPv4 "<IP_HOST>" -RequestCount 70 -IntervalMilliseconds 500
```

**En el host**, inyecta la falla:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Invoke-ChaosTest.ps1 `
  -HoldSeconds 15
```

El script elige `app1`, `app2` o `app3` al azar, lo detiene y **siempre** lo
restaura en un bloque `finally`. Después espera a que HAProxy lo marque `UP`.
Para fijar el nodo: `-Target app2`. Para revisar sin cambios: `-WhatIf`.

### Qué capturar

| Nodo | Ventana de falla | Sondeos | HTTP 200 | Errores | Disponibilidad | Vuelta a rotación |
|---|---|---|---|---|---|---|
| | | | | | | |

Guarda la salida del monitor y la del host en
`PoCs/evidencias/poc3-chaos-cliente-<fecha>.txt` y
`PoCs/evidencias/poc3-chaos-host-<fecha>.txt`.

## Apagado y arranque

No uses `docker compose down` antes de apagar el equipo: elimina los
contenedores y `restart: always` no puede recrearlos. El flujo recomendado es:

```powershell
# Antes de cerrar el equipo (host)
powershell -NoProfile -ExecutionPolicy Bypass -File .\Stop-Stack.ps1

# Al volver (host)
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-Stack.ps1
```

`Stop-Stack.ps1` usa `docker compose stop`, que envía `SIGTERM` y respeta
`stop_grace_period` (60 s en Galera, 45 s en MongoDB, 20 s en las API). Los
contenedores quedan `Exited (0)` y los datos permanecen en sus volúmenes.
`Start-Stack.ps1` espera a Docker, levanta el stack y valida con
`Test-StackHealth.ps1`. El detalle está en
[Apagado y arranque](../README.md#apagado-y-arranque).

## Scripts incluidos

| Script | Dónde se ejecuta | Función |
|---|---|---|
| `Test-StackHealth.ps1` | Host | Readiness: Docker, 29 servicios, API, catálogo, traza, Galera, VIPs y Nagios. Código `0` = listo. |
| `Invoke-LoadTest.ps1` | Cliente | Carga HTTP de la PoC 1: req/s, latencias p50/p95/p99 y códigos HTTP. |
| `Monitor-LanHealth.ps1` | Cliente | Monitor continuo de `/api/health` para las PoC 2 y 3. |
| `Test-LanFailover.ps1` | Host | PoC 2: failover de API, presentación y aplicación, con restauración garantizada. |
| `Invoke-ChaosTest.ps1` | Host | PoC 3: falla aleatoria de un nodo API con restauración garantizada. |
| `Enable-LanPocFirewall.ps1` | Host (admin) | Crea o actualiza la regla TCP/80 limitada al cliente. |
| `Remove-LanPocFirewall.ps1` | Host (admin) | Elimina la regla de firewall de la PoC. |

En la raíz del repositorio están además `Start-Stack.ps1`, `Stop-Stack.ps1` e
`Install-AutoStart.ps1`.

## Evidencias

Guarda tus capturas en `PoCs/evidencias/`. Esa carpeta está excluida de Git
salvo su propio `README.md`, así que puedes pegar texto, CSV o capturas sin
ensuciar el repositorio. La convención de nombres está en
[`evidencias/README.md`](evidencias/README.md).

Capturas de la ejecución del 26-10-2026:

- `poc1-carga-cliente-2026-10-26.jpeg` y `poc1-carga-host-2026-10-26.jpeg`
- `poc2-failover-cliente-2026-10-26.txt` y `poc2-failover-host-2026-10-26.txt`
- `poc3-chaos-cliente-2026-10-26.txt` y `poc3-chaos-host-2026-10-26.txt`

Los resultados de las tres PoC están resumidos en el
[`README.md`](../README.md#resultados-principales).

## Si Windows bloquea los scripts

Ejecuta cada comando con `powershell -NoProfile -ExecutionPolicy Bypass -File`
(solo afecta a ese proceso). Si una directiva de organización lo impide, no
cambies la política del equipo: consulta al administrador.
