# Pendientes: tecnologías y propuestas adicionales

Posibles incorporaciones al stack descrito en
[PLATFORM-MIGRATION-PLAN.md](./PLATFORM-MIGRATION-PLAN.md). Ninguna de estas
propuestas forma parte del plan aprobado todavía.

## Primeras opciones recomendadas

- [ ] Longhorn (almacenamiento replicado)
- [ ] MinIO + Velero (respaldos y almacenamiento de objetos)
- [ ] KEDA (escalado basado en colas)
- [ ] Kyverno (motor de políticas)
- [ ] Falco (detección en tiempo de ejecución)
- [ ] External Secrets + Vault u OpenBao
- [ ] Cilium (CNI, NetworkPolicies, mTLS y Hubble)
- [ ] Flyway (migraciones de esquema)
- [ ] Renovate (actualizaciones de dependencias y charts)

## Confiabilidad y operación

- [ ] **Respaldo y recuperación ante desastres (DR):** Velero para respaldos
  del clúster y volúmenes; CRD de respaldo de MariaDB Operator y respaldos de
  MongoDB en almacenamiento de objetos. El plan pide pruebas de restauración,
  pero todavía no selecciona herramientas.
- [ ] **Almacenamiento de objetos (MinIO):** destino compartido para
  respaldos y almacenamiento de Loki, Tempo y bloques de Mimir.
- [ ] **Almacenamiento persistente:** `local-path` de K3s no se replica; usar
  Longhorn o Rook-Ceph para cargas con estado.
- [ ] **Escalado automático:** KEDA para escalar según colas (opcional en el
  plan), además de `metrics-server` y VPA.
- [ ] **Despliegue progresivo:** Flagger o Argo Rollouts para canarios con
  reversión automática guiada por métricas de Mimir.

## Seguridad

- [ ] **Motor de políticas:** Kyverno u OPA Gatekeeper (el plan ya contempla
  Kyverno para verificar firmas de cosign).
- [ ] **Detección en tiempo de ejecución:** Falco para detectar actividad de
  contenedores a nivel de llamadas al sistema, como complemento de Wazuh,
  enfocado en hosts.
- [ ] **Secretos:** HashiCorp Vault u OpenBao con External Secrets Operator;
  ofrece más capacidades que SOPS cuando se necesitan rotación o credenciales
  dinámicas para bases de datos.
- [ ] **Identidad:** Keycloak o Authentik para SSO/OIDC de la API y Grafana.
- [ ] **CNI / malla de servicios:** Cilium para NetworkPolicies, mTLS y
  observabilidad de red con Hubble (más ligero que Istio).
- [ ] **Cadena de suministro:** Syft y Grype para SBOM; procedencia SLSA con
  GitHub Attestation Actions.

## Entrega y calidad

- [ ] **Análisis de IaC y pre-commit:** hooks de pre-commit, tflint, Checkov y
  análisis de configuración con Trivy.
- [ ] **Actualización de dependencias:** Renovate (o Dependabot) para charts
  Helm e imágenes; se integra bien con Flux.
- [ ] **Pruebas de carga y caos:** k6 como alternativa a Siege, `ab` y JMeter
  en Kubernetes; Chaos Mesh para inyección de fallas.
- [ ] **Entornos efímeros para PR:** Flux o vcluster para crear un entorno de
  prueba por pull request.

## Datos

- [ ] **Migraciones de esquema:** ejecutar Flyway o Liquibase como Jobs de
  Kubernetes (`ToDo.md` solicita migraciones, pero no selecciona herramienta).
- [ ] **Exporters:** Prometheus exporters para MariaDB, MongoDB, Redis y
  RabbitMQ.

## Otros

- [ ] **Experiencia de desarrollo:** Tilt o Skaffold para iterar en Kubernetes;
  Makefile o Taskfile para agrupar comandos habituales.
- [ ] **Documentación:** registros de decisiones arquitectónicas (ADR), por
  ejemplo, RabbitMQ frente a NATS.
