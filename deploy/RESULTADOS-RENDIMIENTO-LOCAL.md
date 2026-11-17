# Resultados de rendimiento: Kubernetes local

## Entorno y método

- Fecha: 16/11/2026.
- Host: Linux Mint 22.3, Docker Engine 29.10.0.
- Clúster: Minikube 1.39.0, Kubernetes 1.37.2; un nodo con 2 vCPU y 6 GiB.
- Aplicación: API con tres réplicas, web con dos réplicas, MariaDB, MongoDB,
  Redis y el Collector. Todas las réplicas comparten el mismo host y nodo.
- Ruta medida: `kubectl port-forward` → Service web → Nginx → Service API →
  Redis o MariaDB.
- Herramienta: `deploy/scripts/benchmark.py`, Python estándar, sin servicios
  externos. Cada respuesta se valida como HTTP 200 con 10 productos.

El benchmark limpia Redis antes de cada una de 10 solicitudes frías
secuenciales y verifica que la respuesta indique `cache miss`. Luego envía 100
solicitudes con caché caliente y concurrencia 5, y verifica que todas indiquen
`cache hit`. Las latencias incluyen el costo del `port-forward`.

Para repetir la medición, inicia el port-forward en una terminal:

```bash
kubectl -n store port-forward --address 127.0.0.1 service/web 8080:80
```

Y en otra terminal, desde la raíz del repositorio:

```bash
python3 deploy/scripts/benchmark.py --url http://127.0.0.1:8080
```

## Medición realizada

| Escenario | Muestras | Concurrencia | p50 | p95 | p99 | Máximo |
|---|---:|---:|---:|---:|---:|---:|
| Caché fría, consulta MariaDB | 10 | 1 | 10.18 ms | 20.51 ms | 20.51 ms | 20.51 ms |
| Caché caliente, Redis | 100 | 5 | 15.99 ms | 65.99 ms | 157.76 ms | 158.98 ms |

Durante el escenario caliente se observaron 196.09 solicitudes/s y 100/100
respuestas atendidas desde caché. La p95 de la muestra fría coincide con el
máximo porque solo se tomaron 10 muestras. La ejecución caliente fue
concurrente, por lo que su latencia no debe compararse directamente con la
medición fría secuencial.

## Alcance

Es una medición inicial reproducible de una sola ejecución para validar el
recorrido local; no es una comparación antes/después, una prueba sostenida ni
un compromiso de capacidad o disponibilidad. El host, Docker, Minikube, el
`port-forward` y el número reducido de muestras influyen en los resultados.
No representa un clúster multinodo ni una prueba desde otra computadora. Para
un informe final más robusto, repite el benchmark varias veces, conserva la
configuración y reporta la dispersión junto con el uso de CPU y memoria.
