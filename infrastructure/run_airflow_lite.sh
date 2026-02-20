#instalaar doker 
sudo yum update -y
sudo amazon-linux-extras install -y docker
sudo systemctl enable --now docker
docker --version || sudo docker --version
#installar comp¿se

sudo curl -L "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
docker-compose version

#ir a directorio
cd /home/ssm-user/airflow-docker

cat > run_airflow_lite.sh <<'EOF'
#!/bin/bash
set -euo pipefail

PROJECT_DIR="${HOME}/airflow-docker"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.lite.yaml"

cd "${PROJECT_DIR}"

echo "========================================="
echo "Pre-check: Docker y Docker Compose"
echo "========================================="

# Require docker
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker no está instalado o no está en PATH"
  echo "En Amazon Linux 2 instala con:"
  echo "  sudo yum update -y"
  echo "  sudo amazon-linux-extras install -y docker"
  echo "  sudo systemctl enable --now docker"
  exit 1
fi

# Require docker-compose (binario)
if ! command -v docker-compose >/dev/null 2>&1; then
  echo "ERROR: docker-compose no está instalado o no está en PATH"
  echo "Instala docker-compose v2 binario con:"
  echo "  sudo curl -L \"https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64\" -o /usr/local/bin/docker-compose"
  echo "  sudo chmod +x /usr/local/bin/docker-compose"
  exit 1
fi

# Decide whether to use sudo for docker-compose based on docker socket access
if docker ps >/dev/null 2>&1; then
  DC="docker-compose"
else
  DC="sudo docker-compose"
fi

echo "Using: ${DC}"
docker --version
${DC} version

if [ ! -f "${COMPOSE_FILE}" ]; then
  echo "ERROR: No existe ${COMPOSE_FILE}"
  exit 1
fi

echo "========================================="
echo "Validando docker-compose config"
echo "========================================="
${DC} -f "${COMPOSE_FILE}" config >/dev/null
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
${DC} -f "${COMPOSE_FILE}" up airflow-init
INIT_RC=$?
set -e

if [ $INIT_RC -ne 0 ]; then
  echo "ERROR: airflow-init falló. Mostrando logs:"
  ${DC} -f "${COMPOSE_FILE}" logs --tail=200 airflow-init || true
  exit $INIT_RC
fi

echo "========================================="
echo "Levantando servicios (up -d)"
echo "========================================="
${DC} -f "${COMPOSE_FILE}" up -d

echo "========================================="
echo "Estado de contenedores"
echo "========================================="
${DC} -f "${COMPOSE_FILE}" ps

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
echo "  ${DC} -f ${COMPOSE_FILE} logs -f --tail=200 airflow-webserver"
echo "  ${DC} -f ${COMPOSE_FILE} logs -f --tail=200 airflow-scheduler"
echo "  ${DC} -f ${COMPOSE_FILE} logs -f --tail=200 postgres"
echo "  ${DC} -f ${COMPOSE_FILE} down"
echo "  ${DC} -f ${COMPOSE_FILE} down -v  # reset total"
EOF

chmod +x run_airflow_lite.sh
bash -n run_airflow_lite.sh && echo "OK: syntax"
