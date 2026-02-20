#!/bin/bash
set -euo pipefail

PROJECT_DIR="${HOME}/airflow-docker"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.lite.yaml"

cd "${PROJECT_DIR}"

echo "========================================="
echo "Pre-check: Docker y Compose"
echo "========================================="
if ! docker ps >/dev/null 2>&1; then
  DOCKER_CMD="sudo docker"
else
  DOCKER_CMD="docker"
fi

${DOCKER_CMD} version
${DOCKER_CMD} compose version

if [ ! -f "${COMPOSE_FILE}" ]; then
  echo "ERROR: No existe ${COMPOSE_FILE}"
  exit 1
fi

echo "========================================="
echo "Validando docker compose config"
echo "========================================="
${DOCKER_CMD} compose -f "${COMPOSE_FILE}" config >/dev/null
echo "OK: compose config"

echo "========================================="
echo "Creando estructura local (dags/logs/plugins)"
echo "========================================="
mkdir -p dags logs plugins logs/dag_processor_manager
chmod -R 775 dags logs plugins

echo "========================================="
echo "Inicializando Airflow (airflow-init)"
echo "========================================="
set +e
${DOCKER_CMD} compose -f "${COMPOSE_FILE}" up airflow-init
INIT_RC=$?
set -e

if [ $INIT_RC -ne 0 ]; then
  echo "ERROR: airflow-init falló. Mostrando logs:"
  ${DOCKER_CMD} compose -f "${COMPOSE_FILE}" logs --tail=200 airflow-init || true
  exit $INIT_RC
fi

echo "========================================="
echo "Levantando servicios (up -d)"
echo "========================================="
${DOCKER_CMD} compose -f "${COMPOSE_FILE}" up -d

echo "========================================="
echo "Estado de contenedores"
echo "========================================="
${DOCKER_CMD} compose -f "${COMPOSE_FILE}" ps

echo "========================================="
echo "Validación local de UI"
echo "========================================="
curl -fsSI http://localhost:8080 >/dev/null && echo "OK: Airflow responde en localhost:8080" || echo "WARN: aún no responde, revisa logs"

echo
echo "========================================="
echo "Airflow LITE está corriendo"
echo "========================================="
echo "URL: http://<EC2_PUBLIC_IP>:8080"
echo "Usuario: airflow"
echo "Password: airflow"
echo
echo "Comandos útiles:"
echo "  ${DOCKER_CMD} compose -f ${COMPOSE_FILE} logs -f --tail=200 airflow-webserver"
echo "  ${DOCKER_CMD} compose -f ${COMPOSE_FILE} logs -f --tail=200 airflow-scheduler"
echo "  ${DOCKER_CMD} compose -f ${COMPOSE_FILE} logs -f --tail=200 postgres"
echo "  ${DOCKER_CMD} compose -f ${COMPOSE_FILE} down"
echo "  ${DOCKER_CMD} compose -f ${COMPOSE_FILE} down -v  # reset total"
