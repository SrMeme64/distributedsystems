# PoC LAN y failover

Scripts reutilizables para probar el sistema desde una laptop externa (cliente)
contra el host Docker. Describe una prueba realizada y ofrece scripts para
repetirla; no significa que las pruebas futuras o las evoluciones opcionales
del proyecto ya se hayan ejecutado.

## Topología comprobada

- Host Docker: `192.168.1.69`, conectado por Wi-Fi.
- Cliente LAN: `192.168.1.68`.
- La interfaz Wi-Fi del host tenía perfil `Public`; no se cambió el perfil.
- Docker Compose se ejecutó únicamente en el host con `.env.exam`. El cliente
  solo envió solicitudes HTTP.
- Nagios permanece enlazado a `127.0.0.1:8088`; no forma parte de esta PoC LAN.

## Resultados de esta ejecución

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

Durante esta PoC se creó y verificó una regla de entrada para TCP/80 con este
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
| `Monitor-LanHealth.ps1` | Monitoriza la API del host desde el cliente, imprimiendo HTTP status y traza de cada solicitud. |
| `Test-LanFailover.ps1` | Pausa el HAProxy master de la capa indicada, espera el failover al backup y luego recupera el master. |
