# PoC LAN y failover

Scripts reutilizables para probar el sistema desde una laptop externa (cliente)
contra el host Docker. Describe una prueba realizada y ofrece scripts para
repetirla; no significa que las pruebas futuras o las evoluciones opcionales
del proyecto ya se hayan ejecutado.

Los resultados de las PoC 1-3 (carga, failover de API y Chaos Engineering)
ejecutadas el 26-10-2026 están en el [`README.md`](../README.md). Esta carpeta
cubre además el failover de los HAProxy master/backup de presentación y
aplicación.

## Topología comprobada (22-10-2026)

- Host Docker: `192.168.1.69`, conectado por Wi-Fi.
- Cliente LAN: `192.168.1.68`.
- La interfaz Wi-Fi del host tenía perfil `Public`; no se cambió el perfil.
- Docker Compose se ejecutó únicamente en el host con `.env.exam`. El cliente
  solo envió solicitudes HTTP.
- Nagios permanece enlazado a `127.0.0.1:8088`; no forma parte de esta PoC LAN.

Las IP pueden cambiar entre sesiones. Antes de repetir la prueba, obtén la IP
actual del host con `ipconfig | findstr /i "IPv4"` y sustituye los valores de
los comandos.

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

Durante la PoC del 22-10-2026 se creó y verificó una regla de entrada para TCP/80 con este
alcance:

- Dirección local: `192.168.1.69`.
- Dirección remota autorizada: `192.168.1.68`.
- Interfaz: `Wi-Fi`.
- Perfil: `Public`, el perfil activo del host en esa ejecución.
- Edge traversal: bloqueado.

No se cambió el perfil de red ni se abrió el puerto a toda la LAN. La excepción
se autorizó porque ambos equipos estaban en una LAN privada de confianza, pese
a la clasificación `Public` de Windows. El script de alta exige
`-AllowPublicProfile` explícito en ese caso, además de una confirmación. No lo
uses para permitir clientes no confiables. Si el cliente obtiene otra IP, hay
que actualizar la regla o el script deja de coincidir con el cliente autorizado.

Los scripts de firewall necesitan PowerShell como administrador. El de
eliminación comprueba IPs, interfaz y puerto antes de quitar la regla. No se
elimina automáticamente: mantenerla es una decisión del operador mientras
continúen las pruebas LAN.

## PoC 1-3 desde la laptop cliente

Estas son las tres pruebas del [`README.md`](../README.md) ejecutadas desde la
segunda laptop. El host solo detiene y vuelve a iniciar contenedores; el cliente
genera la carga y verifica las respuestas.

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
docker compose --env-file .env.exam start app1
```

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
$target = Get-Random -InputObject @("app1", "app2", "app3")
Write-Host "Nodo seleccionado: $target"
docker compose --env-file .env.exam stop $target
try {
    Start-Sleep -Seconds 15
}
finally {
    docker compose --env-file .env.exam start $target
}
```

**Cómo verificar:** al final, el monitor imprime una línea como
`Resumen: 70 solicitudes, 68 HTTP 200, 2 errores, 97.1 % disponible`. Un valor
alto de disponibilidad con pocos errores en la ventana de falla es el resultado
esperado. Si el resumen no aparece, el monitor se interrumpió antes de terminar.

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
     -HostIPv4 "192.168.1.69" `
     -ClientIPv4 "192.168.1.68" `
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
     -HostIPv4 "192.168.1.69"
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

   El script pide confirmación antes de pausar el master seleccionado. Usa
   `-WhatIf` para revisar sin alterar servicios; solo acepta la confirmación
   cuando el monitor del cliente esté activo. El script intenta reanudar el
   master incluso ante un error. Mantén activo el monitor cliente para
   verificar que el trace remoto muestre el backup y luego el master.

5. Si la regla ya no se necesita, eliminar solo la regla de esta PoC (PowerShell
   elevado en el host):

   ```powershell
   .\PoCs\Remove-LanPocFirewall.ps1 `
     -HostIPv4 "192.168.1.69" `
     -ClientIPv4 "192.168.1.68" `
     -InterfaceAlias "Wi-Fi"
   ```

Los comandos de alta y baja admiten `-WhatIf` para revisar la acción antes de
aplicarla. Revisa siempre las IP, el perfil y la interfaz actuales: pueden
cambiar entre sesiones.

## Scripts incluidos

| Script | Función |
|---|---|
| `Enable-LanPocFirewall.ps1` | Crea una regla de firewall limitada a TCP/80 entre host y cliente por la interfaz correcta. Requiere PowerShell como administrador. |
| `Remove-LanPocFirewall.ps1` | Elimina la regla de firewall creada por `Enable-LanPocFirewall.ps1`. Verifica IPs, interfaz y puerto antes de quitar. |
| `Monitor-LanHealth.ps1` | Monitoriza la API del host desde el cliente, imprimiendo HTTP status, traza y un resumen final de disponibilidad. |
| `Invoke-LoadTest.ps1` | Genera carga HTTP desde el cliente sin instalar `ab`: solicitudes, concurrencia, req/s, latencias p50/p95/p99 y códigos HTTP. |
| `Test-LanFailover.ps1` | Pausa el HAProxy master de la capa indicada, espera el failover al backup y luego recupera el master. |
