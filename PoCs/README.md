# PoC LAN y failover

Scripts reutilizables para probar el sistema desde una laptop externa (cliente)
contra el host Docker. Describe una prueba realizada y ofrece scripts para
repetirla; no significa que las pruebas futuras o las evoluciones opcionales
del proyecto ya se hayan ejecutado.

Los resultados de las PoC 1-3 (carga, failover de API y Chaos Engineering)
ejecutadas el 26-10-2026 están en el [`README.md`](../README.md). Esta carpeta
cubre además el failover de los HAProxy master/backup de presentación y
aplicación.

## Topología comprobada (26-10-2026)

- Host Docker: `192.168.1.72`, conectado por Wi-Fi.
- Cliente LAN: consulta tu IP con `ipconfig` (en la ejecución del 22-10-2026 fue `192.168.1.68`).
- La interfaz Wi-Fi del host tenía perfil `Public`; no se cambió el perfil.
- Docker Compose se ejecutó únicamente en el host con `.env.exam`. El cliente
  solo envió solicitudes HTTP.
- Nagios permanece enlazado a `127.0.0.1:8088`; no forma parte de esta PoC LAN.

Las IP pueden cambiar entre sesiones. Antes de repetir la prueba, obtén la IP
actual del host con `ipconfig | findstr /i "IPv4"` y sustituye los valores de
los comandos. Los resultados del 22-10-2026 que aparecen más abajo usan las IP
históricas `192.168.1.69` y `192.168.1.68`; no las copies sin comprobarlas.

## Resultados de la ejecución del 22-10-2026

- Desde el cliente, `Test-NetConnection 192.168.1.69 -Port 80` informó
  `TcpTestSucceeded: True`.
- `GET http://192.168.1.69/api/health` respondió HTTP 200 desde el cliente.
- Al pausar el master de presentación, la traza cambió de
  `presentation-lb-master` a `presentation-lb-backup`; al reanudarlo volvió al
  master.
- Al pausar el master de aplicación, la traza cambió de
  `application-lb-master` a `application-lb-backup`; al reanudarlo volvió al
  master.
- En cada failover se observaron dos solicitudes con timeout durante la
  convergencia. Después, el backup respondió HTTP 200. Por lo tanto, se
  comprobó failover, pero no continuidad sin interrupciones.
- Estas pruebas no comprueban tolerancia a la caída del host, de
  `presentation-entry`, de MariaDB ni de la red.

## Firewall del host

La regla de entrada para TCP/80 está limitada al host, al cliente y a la
interfaz Wi-Fi. El nombre es estable (`Distributed Store LAN PoC (TCP 80)`) y
`Enable-LanPocFirewall.ps1` es idempotente: si cambia la IP del host o del
cliente, actualiza el alcance de la regla existente en lugar de fallar o dejar
una regla vieja. También elimina las reglas creadas por versiones anteriores del
script, cuyo nombre incluía la IP del cliente.

Alcance de la regla actual:

- Dirección local: la IP LAN actual del host (por ejemplo `192.168.1.72`).
- Dirección remota autorizada: la IP del cliente.
- Interfaz: `Wi-Fi`.
- Perfil: el perfil activo (`Public` en la sesión del 26-10-2026).
- Edge traversal: bloqueado.

No se cambió el perfil de red ni se abrió el puerto a toda la LAN. La excepción
se autorizó porque ambos equipos estaban en una LAN privada de confianza, pese
a la clasificación `Public` de Windows. El script de alta exige
`-AllowPublicProfile` explícito en ese caso, además de una confirmación. No lo
uses para permitir clientes no confiables.

Los scripts de firewall necesitan PowerShell como administrador. El de
eliminación comprueba IPs, interfaz y puerto antes de quitar la regla; usa
`-Force` si cambió la IP y solo quieres limpiar. No se elimina automáticamente:
mantenerla es una decisión del operador mientras continúen las pruebas LAN.

## PoC 1-5 desde la laptop cliente

Estas son las cinco pruebas del [`README.md`](../README.md) ejecutadas desde la
segunda laptop. El host solo detiene, pausa y vuelve a iniciar contenedores; el
cliente genera la carga y verifica las respuestas.

Para la demo no hace falta ejecutar los pasos manuales uno a uno: al final de
esta sección están las **suites automatizadas**, que hacen el *preflight*, lanzan
las PoC en orden y dejan evidencia en `PoCs/evidencias/`.

**Requisitos en el cliente:** Windows 10/11, PowerShell 5.1 o superior, `curl.exe`
y una copia de este repositorio. Si no tiene el repo, clónalo:

```powershell
git clone https://github.com/SrMeme64/distributedsystems.git
cd distributedsystems
```

Si Windows bloquea los scripts, usa `powershell -ExecutionPolicy Bypass -File`
en cada invocación (solo afecta a ese proceso).

### Paso 0: confirmar la ruta cliente → host

En el **host**, obtén su IP LAN:

```powershell
ipconfig | findstr /i "IPv4"
```

En el **cliente**, obtén tu IP y prueba el puerto 80 (sustituye `<IP_HOST>`):

```powershell
ipconfig | findstr /i "IPv4"
Test-NetConnection <IP_HOST> -Port 80
curl.exe -i http://<IP_HOST>/api/health
```

- `TcpTestSucceeded: True` y `HTTP/1.1 200 OK` → no hace falta tocar el firewall.
- `TcpTestSucceeded: False` → en el host, PowerShell como administrador:

  ```powershell
  .\PoCs\Enable-LanPocFirewall.ps1 `
    -HostIPv4 "<IP_HOST>" `
    -ClientIPv4 "<IP_CLIENTE>" `
    -InterfaceAlias "Wi-Fi" `
    -AllowPublicProfile
  ```

  `-AllowPublicProfile` solo es necesario si la interfaz está clasificada como
  `Public`. Vuelve a ejecutar `Test-NetConnection` hasta obtener `True`.

### PoC 1: carga desde el cliente (sin instalar `ab`)

En el **host**, vacía la caché:

```powershell
curl.exe -sS -o NUL -w "cache_clear HTTP %{http_code}`n" -X POST http://localhost/api/cache/clear
```

En el **cliente**, mide la caché fría y luego la caliente:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Invoke-LoadTest.ps1 `
  -BaseUrl "http://<IP_HOST>" -Requests 1 -Concurrency 1

powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Invoke-LoadTest.ps1 `
  -BaseUrl "http://<IP_HOST>" -Requests 500 -Concurrency 20
```

**Cómo verificar:** en la salida, `Errores: 0`, `Codigos HTTP: 200=...`, y la
caché caliente debe mostrar más `Req/s` y menor latencia que la fría. En la
ejecución del 26-10-2026 desde el host se obtuvo 54.7 ms en frío y 926.38 req/s
con 18.4 ms de media en caliente (20 de concurrencia).

### PoC 2: failover simple desde el cliente

En el **cliente**, línea base (3 sondeos):

```powershell
$baseUrl = "http://<IP_HOST>"
1..3 | ForEach-Object {
    curl.exe -sS -i "$baseUrl/api/health" |
        Select-String -Pattern "^HTTP/|^x-request-trace:"
    Start-Sleep -Milliseconds 500
}
```

En el **host**, detén `app1`:

```powershell
docker compose --env-file .env.exam stop app1
```

En el **cliente**, 10 sondeos con `app1` caído:

```powershell
$ok = 0; $err = 0
1..10 | ForEach-Object {
    $r = curl.exe -sS -i --max-time 5 "$baseUrl/api/health" 2>&1
    $status = ($r | Select-String -Pattern "^HTTP/").Line
    $trace = ($r | Select-String -Pattern "^x-request-trace:").Line
    if ($status -match "200") { $ok++ } else { $err++ }
    "{0} | {1}" -f $status, $trace
    Start-Sleep -Milliseconds 700
}
"HTTP 200: $ok | errores: $err"
```

En el **host**, recupera el nodo:

```powershell
docker compose --env-file .env.exam up -d --no-deps app1
docker compose --env-file .env.exam ps app1
```

Usa `up -d --no-deps` en lugar de `start`: `start` también vuelve a lanzar los
servicios de inicialización (`db-bootstrap`, `mongo-init`, `catalog-init`), lo
que alarga la prueba sin aportar nada.

`ps app1` debe mostrar `Up`. HAProxy necesita dos chequeos correctos
(`rise 2`, intervalo de 1 s) antes de devolverlo a la rotación, así que espera
unos 4 s y confirma:

```powershell
Start-Sleep -Seconds 4
docker logs --tail 30 distributed-three-tier-application-lb-master-1 2>&1 |
    Select-String "app1 is UP"
```

Si `ps app1` sigue en `Exited`, usa `up -d app1` y revisa `docker logs
distributed-three-tier-app1-1`. Un `Exited (0)` es una parada limpia; un
`Exited (1)` o reinicios indican un fallo de la app.

En el **cliente**, confirma que `app1` vuelve a la rotación:

```powershell
1..6 | ForEach-Object {
    curl.exe -sS -i "$baseUrl/api/health" |
        Select-String -Pattern "^HTTP/|^x-request-trace:"
    Start-Sleep -Milliseconds 700
}
```

**Cómo verificar:** durante la caída, `HTTP 200: 10 | errores: 0` y las trazas
solo muestran `app2`/`app3`. Tras recuperar, la traza vuelve a incluir `app1`.
En la convergencia inicial pueden aparecer timeouts; es esperado.

### PoC 3: Chaos Engineering desde el cliente

En el **cliente**, inicia el monitor (70 sondeos cada 500 ms, ~35 s):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Monitor-LanHealth.ps1 `
  -HostIPv4 "<IP_HOST>" -RequestCount 70 -IntervalMilliseconds 500
```

Mientras el monitor imprime líneas, en el **host** inyecta la falla:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Invoke-ChaosTest.ps1 `
  -HoldSeconds 15
```

El script elige un nodo al azar, lo detiene 15 s y **siempre** lo restaura en un
bloque `finally`, incluso si pulsas `Ctrl+C`. Luego espera a que HAProxy lo
marque `UP`. Usa `-Target app2` para fijar el nodo y `-WhatIf` para revisar sin
cambios.

**Cómo verificar:** al final, el monitor imprime una línea como
`Resumen: 70 solicitudes, 68 HTTP 200, 2 errores, 97.1 % disponible`. Un valor
alto de disponibilidad con pocos errores en la ventana de falla es el resultado
esperado. Si el resumen no aparece, el monitor se interrumpió antes de terminar.

### PoC 4 y 5: failover de los HAProxy master

Estas dos PoC prueban la capa de balanceo, no los nodos API:

- **PoC 4:** `presentation-lb-master` cede el VIP `172.30.0.250` a `presentation-lb-backup`.
- **PoC 5:** `application-lb-master` cede el VIP `172.31.0.250` a `application-lb-backup`.

**En el cliente**, deja activo el monitor o la suite del cliente (ver más abajo).

**En el host**, ejecuta una capa y luego la otra:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Test-LanFailover.ps1 `
  -Layer Presentation -HoldSeconds 12

powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Test-LanFailover.ps1 `
  -Layer Application -HoldSeconds 12
```

El script **pausa** el master en lugar de detenerlo: el sidecar Keepalived
comparte su *network namespace* y pausar conserva ese namespace para que el VIP
pueda migrar. Después reanuda el master y mide el *failback*. Un bloque
`finally` garantiza la restauración incluso con `Ctrl+C`. Usa `-WhatIf` para
revisar sin cambios.

**Cómo verificar:** la salida debe terminar en `Resultado: PASS` con dos tiempos,
por ejemplo:

```text
Resumen Presentation :
  Failover presentation-lb-master -> presentation-lb-backup : 10.37 s (2 errores)
  Failback presentation-lb-backup -> presentation-lb-master : 3.38 s (0 errores)
  Resultado: PASS
```

En el cliente, la traza debe pasar de `presentation-lb-master` a
`presentation-lb-backup` y volver. Los ~10 s incluyen el timeout del sondeo en
curso; la migración directa del VIP ocurre en ~7.7 s.

### Suites automatizadas

Las suites agrupan las PoC, verifican el estado antes y después de cada una y
escriben la evidencia en `PoCs/evidencias/`.

**Readiness del stack (host):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Test-StackHealth.ps1
```

Verifica Docker, 29 servicios, `/api/health`, catálogo, traza, Galera, ambos VIP
y Nagios. Sale con código `0` solo si todo está listo.

**Suite del host (PoC 2-5):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Invoke-HostPocSuite.ps1 `
  -HoldSeconds 12
```

Ejecuta PoC 2 (`app1`), PoC 3 (nodo aleatorio), PoC 4 (presentación) y PoC 5
(aplicación). Hace *preflight*, repara el stack si hace falta y verifica el
estado después de cada escenario. Puedes elegir escenarios con
`-Scenarios poc4,poc5`.

**Suite del cliente (conectividad, PoC 1 y monitor):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PoCs\Invoke-ClientPocSuite.ps1 `
  -HostIPv4 "<IP_HOST>" -MonitorSeconds 240
```

Hace *preflight*, vacía la caché, mide carga fría y caliente, monitoriza
`/api/health` durante la ventana indicada y calcula disponibilidad, failovers y
failbacks. Si el *preflight* falla, imprime el comando de firewall exacto.

**Flujo recomendado para la demo:**

1. En el host: `Test-StackHealth.ps1` hasta ver `LISTO para la demo`.
2. En el cliente: `Invoke-ClientPocSuite.ps1 -HostIPv4 "<IP_HOST>" -MonitorSeconds 240`.
3. En el host, mientras corre el monitor: `Invoke-HostPocSuite.ps1 -HoldSeconds 12`.
4. Revisar el resumen de ambas suites y los archivos de `PoCs/evidencias/`.

**Resultado integrado del 26-10-2026:** host 4/4 PASS (PoC 4 failover 10.37 s,
PoC 5 failover 10.31 s); cliente 327 muestras en 200.4 s, 321 `HTTP 200`, 6
timeouts y **98.2 %** de disponibilidad. Failover de presentación 9.59 s y de
aplicación 9.62 s vistos desde el cliente.

## Cómo repetir

Desde PowerShell en la raíz del repositorio, después de confirmar la IP actual
del host y del cliente:

Si Windows bloquea la ejecución de scripts, revisa primero
`Get-ExecutionPolicy -List`. En una consola personal no administrada por
directivas de organización, se puede habilitar temporalmente solo para la
sesión actual:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
```

Este cambio desaparece al cerrar esa consola. No cambies la política del equipo
ni uses `Unrestricted` para esta PoC; si una directiva de organización lo
bloquea, consulta al administrador.

1. En el host, comprobar el perfil e IP actuales:

   ```powershell
   Get-NetConnectionProfile
   Get-NetIPConfiguration
   ```

2. Si TCP/80 no es accesible, abrir PowerShell como administrador en el host y
   crear una regla limitada a ambas direcciones y a la interfaz correcta:

   ```powershell
   .\PoCs\Enable-LanPocFirewall.ps1 `
     -HostIPv4 "192.168.1.72" `
     -ClientIPv4 "<IP_CLIENTE>" `
     -InterfaceAlias "Wi-Fi" `
     -AllowPublicProfile
   ```

   `-AllowPublicProfile` solo permite considerar la categoría actual `Public`;
   no cambia esa categoría ni amplía las IP autorizadas. Omite el parámetro si
   la red no es privada y confiable. Antes de agregar una regla en una red
   pública, consulta al administrador de la red.

3. En la laptop cliente, monitorizar la traza de la API:

   ```powershell
   .\PoCs\Monitor-LanHealth.ps1 `
     -HostIPv4 "192.168.1.72"
   ```

   O, mejor, lanzar la suite completa del cliente:

   ```powershell
   .\PoCs\Invoke-ClientPocSuite.ps1 `
     -HostIPv4 "192.168.1.72" -MonitorSeconds 240
   ```

4. Mientras el monitor del cliente imprime respuestas, ejecutar desde otra
   terminal del host, en la raíz del repositorio, primero la capa de
   presentación:

   ```powershell
   .\PoCs\Test-LanFailover.ps1 `
     -Layer Presentation
   ```

   Repetir para la capa de aplicación:

   ```powershell
   .\PoCs\Test-LanFailover.ps1 `
     -Layer Application
   ```

   O ejecutar las cuatro PoC del host en orden:

   ```powershell
   .\PoCs\Invoke-HostPocSuite.ps1 -HoldSeconds 12
   ```

   El script pide confirmación antes de pausar el master seleccionado. Usa
   `-WhatIf` para revisar sin alterar servicios; solo acepta la confirmación
   cuando el monitor del cliente esté activo. El script intenta reanudar el
   master incluso ante un error. Mantén activo el monitor cliente para
   verificar que el trace remoto muestre el backup y luego el master.

5. Si la regla ya no se necesita, eliminar solo la regla de esta PoC (PowerShell
   elevado en el host):

   ```powershell
   .\PoCs\Remove-LanPocFirewall.ps1 `
     -HostIPv4 "192.168.1.72" `
     -ClientIPv4 "<IP_CLIENTE>" `
     -InterfaceAlias "Wi-Fi"
   ```

Los comandos de alta y baja admiten `-WhatIf` para revisar la acción antes de
aplicarla. Revisa siempre las IP, el perfil y la interfaz actuales: pueden
cambiar entre sesiones.

## Scripts incluidos

| Script | Dónde se ejecuta | Función |
|---|---|---|
| `Test-StackHealth.ps1` | Host | Readiness integral: Docker, 29 servicios, API, catálogo, traza, Galera, VIPs y Nagios. Código `0` = listo. |
| `Invoke-HostPocSuite.ps1` | Host | Suite PoC 2-5 con *preflight*, reparación y verificación posterior; escribe evidencia. |
| `Invoke-ClientPocSuite.ps1` | Cliente | *Preflight*, PoC 1 de carga, monitor continuo, detección de failover/failback y CSV. |
| `Enable-LanPocFirewall.ps1` | Host (admin) | Crea o actualiza una regla idempotente limitada a TCP/80 entre host y cliente por la interfaz correcta. |
| `Remove-LanPocFirewall.ps1` | Host (admin) | Elimina la regla de la PoC; verifica IPs, interfaz y puerto, o usa `-Force` para limpiar. |
| `Monitor-LanHealth.ps1` | Cliente | Monitoriza la API del host, imprimiendo HTTP status, traza y un resumen final de disponibilidad. |
| `Invoke-LoadTest.ps1` | Cliente | Genera carga HTTP sin instalar `ab`: solicitudes, concurrencia, req/s, latencias p50/p95/p99 y códigos HTTP. |
| `Test-LanFailover.ps1` | Host | Pausa el HAProxy master de la capa indicada, espera el failover al backup, mide tiempos y recupera el master. |
| `Invoke-ChaosTest.ps1` | Host | Detiene un nodo API aleatorio (o `-Target`) durante `-HoldSeconds` y lo restaura siempre en un bloque `finally`, verificando que HAProxy lo marque `UP`. |

## Arranque automático

El arranque automático se instala desde la raíz del repositorio, no desde esta
carpeta:

```powershell
# Instalar (acceso en la carpeta Startup, sin permisos de administrador)
powershell -NoProfile -ExecutionPolicy Bypass -File ..\Install-AutoStart.ps1

# Alternativa con el Programador de tareas
powershell -NoProfile -ExecutionPolicy Bypass -File ..\Install-AutoStart.ps1 -UseScheduledTask

# Quitar
powershell -NoProfile -ExecutionPolicy Bypass -File ..\Install-AutoStart.ps1 -Remove
```

`..\Start-Stack.ps1` espera a Docker, ejecuta `docker compose up -d`, valida con
`Test-StackHealth.ps1` y deja el log en `PoCs/evidencias/start-stack.log`.
Activa además **Docker Desktop → Settings → General → Start Docker Desktop when
you sign in**.
