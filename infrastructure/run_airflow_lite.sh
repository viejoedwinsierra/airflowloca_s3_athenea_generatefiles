cat > run_airflow_lite.sh <<'EOF'
#!/bin/bash

set -e

PROJECT_DIR="${HOME}/airflow-docker"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.lite.yaml"

cd "${PROJECT_DIR}"

echo "========================================="
echo "Verificando Docker"
echo "========================================="

if ! docker ps >/dev/null 2>&1; then
  DOCKER_CMD="sudo docker"
else
  DOCKER_CMD="docker"
fi

echo "========================================="
echo "Inicializando Airflow (solo primera vez)"
echo "========================================="
${DOCKER_CMD} compose -f "${COMPOSE_FILE}" up airflow-init

echo "========================================="
echo "Levantando servicios"
echo "========================================="
${DOCKER_CMD} compose -f "${COMPOSE_FILE}" up -d

echo "========================================="
echo "Estado de contenedores"
echo "========================================="
${DOCKER_CMD} compose -f "${COMPOSE_FILE}" ps

echo
echo "========================================="
echo "Airflow LITE está corriendo"
echo "========================================="
echo "URL: http://<EC2_PUBLIC_IP>:8080"
echo "Usuario: airflow"
echo "Password: airflow"
echo
echo "Comandos útiles:"
echo "  ${DOCKER_CMD} compose -f ${COMPOSE_FILE} logs --tail=200 airflow-webserver"
echo "  ${DOCKER_CMD} compose -f ${COMPOSE_FILE} down"
echo "  ${DOCKER_CMD} compose -f ${COMPOSE_FILE} down -v  # reset total"
EOF

chmod +x run_airflow_lite.sh
