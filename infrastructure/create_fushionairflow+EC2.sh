#!/bin/bash
# ==============================================================
# Airflow Lite + Diagnóstico - AWS Academy (EC2)
# Compatible: Amazon Linux 2 / Amazon Linux 2023
# Objetivo: correr Airflow en modo ligero (SequentialExecutor)
# ==============================================================

set -euo pipefail

AIRFLOW_VERSION="2.10.3"
PROJECT_DIR="${HOME}/airflow-docker"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.lite.yaml"
PORT="8080"

log() { echo -e "\n=========================================\n$*\n========================================="; }

fail_diag() {
  echo -e "\n❌ ERROR: $1\n"
  echo "==> Diagnóstico rápido:"
  echo "---- whoami / groups ----"
  whoami || true
  id || true

  echo "---- docker socket ----"
  ls -l /var/run/docker.sock || true

  echo "---- docker status ----"
  sudo systemctl status docker --no-pager || true
  sudo service docker status || true

  echo "---- compose version ----"
  docker compose version || true
  docker --help | head -n 40 || true

  echo "---- recursos ----"
  free -h || true
  df -h / || true

  echo "---- contenedores ----"
  if [ -d "${PROJECT_DIR}" ]; then
    cd "${PROJECT_DIR}" || true
    (sudo docker compose -f "${COMPOSE_FILE}" ps || docker compose -f "${COMPOSE_FILE}" ps) 2>/dev/null || true
    (sudo docker compose -f "${COMPOSE_FILE}" logs --tail=200 || docker compose -f "${COMPOSE_FILE}" logs --tail=200) 2>/dev/null || true
  fi

  echo -e "\n👉 Siguiente acción típica:"
  echo "- Si ves 'permission denied' al docker.sock: ejecuta 'newgrp docker' o cierra sesión y entra de nuevo."
  echo "- Si ves 'compose is not a docker command': instala docker-compose-plugin."
  echo "- Si ves RAM < 2GB o disco < 8GB: usa Airflow Lite (este script) y evita el docker-compose oficial completo."
  exit 1
}

trap 'fail_diag "Falló el script en la línea ${LINENO}. Revisa el output anterior."' ERR

log "1) Identificando sistema"
cat /etc/os-release | head -n 10

log "2) Actualizando sistema"
if command -v dnf >/dev/null 2>&1; then
  sudo dnf -y update
else
  sudo yum -y update
fi

log "3) Instalando Docker"
if ! command -v docker >/dev/null 2>&1; then
  if command -v amazon-linux-extras >/dev/null 2>&1; then
    sudo amazon-linux-extras install docker -y
  else
    sudo dnf install -y docker
  fi
fi

log "4) Habilitando y arrancando Docker"
sudo systemctl enable --now docker || (sudo service docker start && sudo chkconfig docker on)

log "5) Agregando usuario al grupo docker (para no usar sudo)"
sudo usermod -aG docker "$USER" || true

log "6) Instalando Docker Compose (plugin preferido)"
if ! docker compose version >/dev/null 2>&1; then
  # Intento 1: plugin por dnf/yum
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y docker-compose-plugin || true
  else
    sudo yum install -y docker-compose-plugin || true
  fi
fi

# Si aún no existe, instalamos binario
if ! docker compose version >/dev/null 2>&1; then
  sudo mkdir -p /usr/libexec/docker/cli-plugins
  sudo curl -sSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
    -o /usr/libexec/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/libexec/docker/cli-plugins/docker-compose
fi

log "7) Validando Docker + Compose"
docker --version
docker compose version

log "8) Validando permisos del daemon (docker.sock)"
# Si no tienes permisos aún, usamos sudo para no bloquearte.
if docker ps >/dev/null 2>&1; then
  DOCKER_CMD="docker"
  echo "OK: docker sin sudo funciona."
else
  DOCKER_CMD="sudo docker"
  echo "AVISO: docker requiere sudo en esta sesión (normal tras usermod). Seguimos con sudo."
  echo "TIP: al final ejecuta 'newgrp docker' o reconecta la sesión para que docker funcione sin sudo."
fi

log "9) Validando recursos mínimos (sandbox-friendly)"
RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
DISK_GB=$(df -BG / | awk 'NR==2{gsub("G","",$4);print $4}')
echo "RAM (GB): ${RAM_GB:-unknown}"
echo "Disco libre / (GB): ${DISK_GB:-unknown}"

if [ "${RAM_GB:-0}" -lt 2 ]; then
  echo "AVISO: RAM < 2GB. Airflow completo NO va a correr. Airflow Lite puede funcionar pero justo."
fi
if [ "${DISK_GB:-0}" -lt 8 ]; then
  echo "AVISO: Disco libre < 8GB. Podrías tener problemas al descargar imágenes."
fi

log "10) Creando estructura del proyecto en ${PROJECT_DIR}"
mkdir -p "${PROJECT_DIR}"/{dags,logs,plugins}
cd "${PROJECT_DIR}"

log "11) Escribiendo docker-compose.lite.yaml (Airflow ligero)"
cat > "${COMPOSE_FILE}" <<EOF
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: airflow
      POSTGRES_PASSWORD: airflow
      POSTGRES_DB: airflow
    volumes:
      - postgres-db-volume:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "airflow"]
      interval: 10s
      retries: 10
    restart: always

  airflow-init:
    image: apache/airflow:${AIRFLOW_VERSION}
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      AIRFLOW__CORE__EXECUTOR: SequentialExecutor
      AIRFLOW__DATABASE__SQL_ALCHEMY_CONN: postgresql+psycopg2://airflow:airflow@postgres/airflow
      AIRFLOW__CORE__LOAD_EXAMPLES: 'false'
      _AIRFLOW_WWW_USER_USERNAME: airflow
      _AIRFLOW_WWW_USER_PASSWORD: airflow
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
    command: >
      bash -c "
      airflow db migrate &&
      airflow users create
        --role Admin
        --username \${_AIRFLOW_WWW_USER_USERNAME}
        --password \${_AIRFLOW_WWW_USER_PASSWORD}
        --firstname Admin
        --lastname User
        --email admin@example.com
      || true
      "

  airflow-webserver:
    image: apache/airflow:${AIRFLOW_VERSION}
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      AIRFLOW__CORE__EXECUTOR: SequentialExecutor
      AIRFLOW__DATABASE__SQL_ALCHEMY_CONN: postgresql+psycopg2://airflow:airflow@postgres/airflow
      AIRFLOW__CORE__LOAD_EXAMPLES: 'false'
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
    ports:
      - "${PORT}:8080"
    command: webserver
    restart: always

  airflow-scheduler:
    image: apache/airflow:${AIRFLOW_VERSION}
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      AIRFLOW__CORE__EXECUTOR: SequentialExecutor
      AIRFLOW__DATABASE__SQL_ALCHEMY_CONN: postgresql+psycopg2://airflow:airflow@postgres/airflow
      AIRFLOW__CORE__LOAD_EXAMPLES: 'false'
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
    command: scheduler
    restart: always

volumes:
  postgres-db-volume:
EOF

log "12) Inicializando Airflow (una sola vez)"
${DOCKER_CMD} compose -f "${COMPOSE_FILE}" up airflow-init

log "13) Levantando servicios"
${DOCKER_CMD} compose -f "${COMPOSE_FILE}" up -d

log "14) Estado de contenedores"
${DOCKER_CMD} compose -f "${COMPOSE_FILE}" ps

log "15) Verificando que el webserver responda localmente"
# Espera corta
sleep 10
if command -v curl >/dev/null 2>&1; then
  curl -sSf "http://localhost:${PORT}" >/dev/null && echo "OK: Airflow UI responde en localhost:${PORT}" \
    || echo "AVISO: aún no responde, revisa logs (puede tardar 20-60s en primer arranque)."
else
  echo "curl no disponible, omitiendo chequeo HTTP."
fi

log "16) Logs (últimas líneas) por si quieres validación rápida"
${DOCKER_CMD} compose -f "${COMPOSE_FILE}" logs --tail=50 airflow-webserver || true
${DOCKER_CMD} compose -f "${COMPOSE_FILE}" logs --tail=50 airflow-scheduler || true

log "✅ Listo"
echo "Airflow UI:"
echo "  http://<EC2_PUBLIC_IP>:${PORT}"
echo "Credenciales:"
echo "  user: airflow"
echo "  pass: airflow"
echo
echo "Comandos útiles:"
echo "  ${DOCKER_CMD} compose -f ${COMPOSE_FILE} ps"
echo "  ${DOCKER_CMD} compose -f ${COMPOSE_FILE} logs --tail=200 airflow-webserver"
echo "  ${DOCKER_CMD} compose -f ${COMPOSE_FILE} down"
echo "  ${DOCKER_CMD} compose -f ${COMPOSE_FILE} down -v   # reset total"
