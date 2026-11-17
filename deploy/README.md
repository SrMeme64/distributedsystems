# Despliegue local en Kubernetes

El overlay local ejecuta un entorno de desarrollo en un nodo Minikube. No es
una configuración de producción ni ofrece alta disponibilidad: todo el clúster
y sus datos dependen de este equipo.

## Requisitos

- Linux, Docker Engine, `kubectl` y Minikube.
- Al menos 8 GB de memoria disponible mientras se ejecuta el clúster.
- `.env.exam` en la raíz del repositorio con los ajustes locales de bases de
  datos requeridos.

Las herramientas de Kubernetes instaladas para este equipo están en
`$HOME/.local/bin`. Agrega esa ruta a la sesión antes de seguir los comandos:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

El overlay usa una instancia de MariaDB, una instancia independiente de
MongoDB, Redis descartable y un StatefulSet de RabbitMQ de un solo nodo con un
volumen persistente. El worker consume mensajes durables de `reviews.created`,
reintenta fallas transitorias y envía a la DLQ los mensajes inválidos o que
agoten sus reintentos. Los PersistentVolumeClaims conservan los datos de las
bases y de la cola entre reinicios; Redis es descartable intencionalmente.
Grafana, Loki, Tempo y Prometheus se ejecutan como un stack LGTM de desarrollo
con recursos limitados fuera de Minikube.
RabbitMQ local no es una configuración HA de producción. Los operadores de
bases de datos, Flux, Terraform y Wazuh siguen pendientes para fases
posteriores.

El perfil anterior `distributed-local` de tres nodos se dejó detenido y sus
volúmenes no se eliminaron. La guía usa `distributed-local-one-node`; ambos
perfiles tienen datos independientes.

El provisionador `hostPath` de Minikube no aplica la propiedad de `fsGroup` al
volumen de RabbitMQ. Por eso, el overlay local usa un init container con la
capacidad `CHOWN` para preparar el directorio; el broker se ejecuta como UID
100 y sin capacidades. En producción se debe usar almacenamiento administrado
por un operador o una política de propiedad compatible con el CSI elegido, no
esta solución local.

## Construir y desplegar

Desde la raíz del repositorio:

```bash
docker compose --env-file .env.exam stop
docker compose -f resilience-lab/docker-compose.yml stop
minikube start --profile=distributed-local-one-node --driver=docker --nodes=1 --cpus=2 --memory=6144 --disk-size=20g --kubernetes-version=v1.37.2
./deploy/scripts/build-images.sh
./deploy/overlays/local/create-secrets.sh
./deploy/observability/start-local.sh
kubectl apply -k deploy/overlays/local
kubectl -n store rollout status statefulset/mariadb --timeout=5m
kubectl -n store rollout status statefulset/mongodb --timeout=5m
kubectl -n store rollout status statefulset/rabbitmq --timeout=5m
kubectl -n store rollout status deployment/api --timeout=5m
kubectl -n store rollout status deployment/review-worker --timeout=5m
kubectl -n store rollout status deployment/web --timeout=5m
kubectl -n store port-forward service/web 8080:80
```

Deja activo el `port-forward` y abre `http://localhost:8080/`.
`/api/healthz` es la sonda de vida; `/api/readyz` comprueba la dependencia
obligatoria MariaDB; `/api/health` informa el estado de todas las dependencias
de la API. Ejecuta las comprobaciones funcionales repetibles desde otra
terminal con `./deploy/scripts/smoke.sh`.

Para medir la ruta de catálogo desde otra terminal, ejecuta
`python3 deploy/scripts/benchmark.py --url http://127.0.0.1:8080`. El script
invalida la caché para tomar 10 muestras frías y luego mide 100 solicitudes
con caché caliente y concurrencia 5. Consulta los
[resultados locales](./RESULTADOS-RENDIMIENTO-LOCAL.md); son mediciones de
desarrollo a través de `kubectl port-forward`, no un SLO de producción.

## Respaldo local

Genera un respaldo de MariaDB, MongoDB y las definiciones de RabbitMQ con:

```bash
./deploy/scripts/backup-local.sh
```

Los archivos se guardan por defecto bajo
`$HOME/.local/share/distributed-store/backups/` con acceso de usuario. Para
elegir otro directorio, pásalo como primer argumento. No subas estos archivos
al repositorio: contienen datos de la aplicación. MongoDB se exporta como
archivo comprimido; RabbitMQ exporta definiciones de exchanges, colas y
bindings, pero no los mensajes encolados. Estos últimos permanecen en el PVC
local, que no sustituye un respaldo externo. La restauración y su ensayo en
bases aisladas se pueden validar sin tocar los datos actuales:

```bash
./deploy/scripts/verify-backup-local.sh \
  "$HOME/.local/share/distributed-store/backups/<directorio-del-respaldo>"
```

La verificación restaura MariaDB y MongoDB en bases temporales y las
definiciones RabbitMQ en un vhost temporal; después elimina esos recursos de
prueba. No restaura ni respalda mensajes de RabbitMQ.

## Telemetría local

La API envía trazas y métricas por OTLP al Collector ligero. El Collector
reenvía la telemetría a Grafana, Loki, Tempo y Prometheus en el contenedor LGTM
local. Grafana está disponible en `http://127.0.0.1:3000`, con el dashboard
**Distributed Store API** como página de inicio. La contraseña administrativa
generada se guarda con permisos `0600` en
`deploy/overlays/local/secrets/lgtm.env`. La interfaz y los puertos de consulta
de Grafana solo se enlazan a loopback; los puertos OTLP se enlazan a la red
privada de Docker de Minikube. Esta instalación usa Prometheus en lugar de
Mimir y es solo para desarrollo y pruebas.

La API también exporta spans de MySQL2 y MongoDB, y una métrica de baja
cardinalidad para resultados de caché. Los spans de Redis registran solo el
nombre del comando y el sistema: no incluyen claves ni valores. Las sentencias
SQL se enmascaran en los spans y se desactiva el reporte detallado de consultas
MongoDB.

El navegador instrumenta las solicitudes `fetch` y exporta sus spans por la
ruta de mismo origen de Nginx `/otlp/v1/traces`. Nginx reenvía `traceparent` y
`tracestate` a la API; los spans de productor y consumidor RabbitMQ propagan el
contexto W3C por los encabezados del mensaje. Nginx reenvía el contexto, pero
no produce spans propios: no hay un módulo nativo compatible con la imagen
Nginx 1.28 Alpine sin privilegios que usa este proyecto.

Consulta el estado del stack local con:

```bash
docker compose --env-file deploy/overlays/local/secrets/lgtm.env \
  -f deploy/observability/compose.yaml ps
```

La imagen LGTM es para desarrollo y pruebas, no para producción. Los datos se
conservan en el volumen Docker `distributed-observability-data`, separado de
los PVC de Kubernetes. Para detenerlo sin borrar la telemetría:

```bash
docker compose --env-file deploy/overlays/local/secrets/lgtm.env \
  -f deploy/observability/compose.yaml stop
```

Las versiones usadas para la implementación local verificada son Minikube
v1.39.0 y `kubectl` v1.37.2. Los scripts de imágenes utilizan configuraciones
Docker temporales y vacías para descargar imágenes públicas; no leen ni
modifican las credenciales Docker del usuario.

Al cambiar el código de la API o de la web, reconstruye y vuelve a cargar las
imágenes; después reinicia los Deployments para que los Pods utilicen las
imágenes `:dev` actualizadas. La imagen web también genera el bundle del SDK
OpenTelemetry del navegador:

```bash
./deploy/scripts/build-images.sh
kubectl -n store rollout restart deployment/api deployment/web
kubectl -n store rollout status deployment/api --timeout=5m
kubectl -n store rollout status deployment/web --timeout=5m
```

No ejecutes al mismo tiempo los stacks completos de Compose y Minikube en este
equipo. Los comandos `stop` conservan los contenedores y volúmenes Compose.
Los volúmenes de las bases de datos de Kubernetes son independientes y se
inician con los datos semilla; esta implementación no migra los datos
existentes de Compose.

Para apagar Minikube sin eliminar sus volúmenes persistentes:

```bash
minikube stop
```

Para volver a Compose, detén Minikube y luego inicia los contenedores
conservados:

```bash
docker compose --env-file deploy/overlays/local/secrets/lgtm.env \
  -f deploy/observability/compose.yaml stop
minikube stop
docker compose --env-file .env.exam start
docker compose -f resilience-lab/docker-compose.yml start
```

Para regresar a Kubernetes, detén ambos stacks Compose y LGTM; ejecuta
`minikube start --profile=distributed-local-one-node` y luego
`./deploy/observability/start-local.sh`.

Los archivos fuente de Secrets generados bajo
`deploy/overlays/local/secrets/` son locales y están excluidos de Git. No los
versiones. Los PVC también contienen datos de desarrollo; no elimines el
perfil Minikube ni los PVC sin tener un respaldo.

La infraestructura K3s con KVM/libvirt se prepara por separado con Terraform
CLI local. Consulta [infra/terraform](../infra/terraform) antes de instalar o
aprovisionar el hipervisor. Las VMs usan 6 GiB de RAM en conjunto; detén
Minikube manualmente antes de aplicarlas si necesitas liberar memoria. El
estado Terraform y los datos del clúster no comparten volúmenes con Minikube.
