#!/bin/bash

# ==============================================================
# Apache Airflow Installation via Docker
# AWS Academy Sandbox - Amazon Linux (AL2/SSM friendly)
# ==============================================================
# Fixes:
#  - docker.sock permission issues in SSM (auto sudo fallback)
#  - low resources warning: optional LITE compose (no redis)
# ==============================================================

set -e

AIRFLOW_DIR="$HOME/airflow-docker"
AIRFLOW_IMAGE="apache/airflow:2.10.3"
COMPOSE_URL="https://airflow.apache.org/docs/apache-airflow/stable/docker-compose.yaml"

echo "========================================="
echo "Updating system"
echo "========================================="
sudo yum update -y

echo "========================================="
echo "Installing Docker"
echo "========================================="
# Works on AL2; if you are on AL2023, docker may already exist or amazon-linux-extras may not exist.
if command -v amazon-linux-extras >/dev/null 2>&1; then
  sudo amazon-linux-extras install docker -y
else
  sudo yum install -y docker || true
fi

sudo service docker start || (sudo systemctl start docker)
# Add current user (SSM often uses ssm-user). Keep ec2-user too for SSH scenarios.
sudo usermod -aG docker ec2-user || true
sudo usermod -aG docker "$(whoami)" || true
sudo chkconfig docker on 2>/dev/null || sudo systemctl enable docker || true

echo "========================================="
echo "Installing Docker Compose plugin (if needed)"
echo "========================================="
if ! sudo docker compose version >/dev/null 2>&1; then
  sudo mkdir -p /usr/libexec/docker/cli-plugins
  sudo curl -sSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
    -o /usr/libexec/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/libexec/docker/cli-plugins/docker-compose
fi

# Decide docker command (SSM permission-safe)
DOCKER="docker"
if ! docker ps >/dev/null 2>&1; then
  DOCKER="sudo docker"
fi

echo "========================================="
echo "Creating Airflow project directory"
echo "========================================="
mkdir -p "${AIRFLOW_DIR}"/{dags,logs,plugins,config}
cd "${AIRFLOW_DIR}"

echo "========================================="
echo "Downloading official Airflow docker-compose file"
echo "========================================="
curl -sSL -o docker-compose.yaml "${COMPOSE_URL}"

echo "========================================="
echo "Creating .env file"
echo "========================================="
cat > .env <<EOF
AIRFLOW_IMAGE_NAME=${AIRFLOW_IMAGE}
AIRFLOW_UID=50000
AIRFLOW_GID=0
EOF

# ---- Resource check (RAM + Disk) ----
MEM_GB=$(free -m | awk '/Mem:/ {printf "%.1f", $2/1024}')
DISK_GB=$(df -BG --output=avail / | tail -n 1 | tr -dc '0-9')

echo "========================================="
echo "Resource check"
echo "========================================="
echo "Detected RAM:  ${MEM_GB} GB"
echo "Disk free:     ${DISK_GB} GB"

USE_LITE="false"
# Airflow compose warns below 4GB; disk recommended >= 10GB
if awk "BEGIN {exit !(${MEM_GB} < 4.0)}"; then
  echo "WARNING: RAM < 4GB. Airflow may be unstable with the default compose."
  USE_LITE="true"
fi
if [ "${DISK_GB}" -lt 10 ]; then
  echo "WARNING: Disk free < 10GB. You may fail pulling images/creating volumes."
  USE_LITE="true"
fi

# ---- If low resources, create a minimal compose (no redis) with minimal changes ----
if [ "${USE_LITE}" = "true" ]; then
  echo "========================================="
  echo "Using LITE compose (no Redis) due to low resources"
  echo "========================================="

  cat > docker-compose.lite.yaml <<'LITE'
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
      retries: 5
      start_period: 5s
    restart: always

  airflow-init:
    image: ${AIRFLOW_IMAGE_NAME:-apache/airflow:2.10.3}
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      AIRFLOW__CORE__EXECUTOR: SequentialExecutor
      AIRFLOW__DATABASE__SQL_ALCHEMY_CONN: postgresql+psycopg2://airflow:airflow@postgres/airflow
      AIRFLOW__CORE__LOAD_EXAMPLES: 'false'
      _AIRFLOW_DB_MIGRATE: 'true'
      _AIRFLOW_WWW_USER_CREATE: 'true'
      _AIRFLOW_WWW_USER_USERNAME: airflow
      _AIRFLOW_WWW_USER_PASSWORD: airflow
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
    command: ["bash","-c","airflow db migrate && airflow users create --role Admin --username airflow --password airflow --firstname Admin --lastname User --email admin@example.com || true"]

  airflow-webserver:
    image: ${AIRFLOW_IMAGE_NAME:-apache/airflow:2.10.3}
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
      - "8080:8080"
    command: ["bash","-c","airflow webserver"]
    restart: always

  airflow-scheduler:
    image: ${AIRFLOW_IMAGE_NAME:-apache/airflow:2.10.3}
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
    command: ["bash","-c","airflow scheduler"]
    restart: always

volumes:
  postgres-db-volume:
LITE

  COMPOSE_FILE="docker-compose.lite.yaml"
else
  echo "========================================="
  echo "Using OFFICIAL compose (default)"
  echo "========================================="
  COMPOSE_FILE="docker-compose.yaml"
fi

echo "========================================="
echo "Initializing Airflow (creating database and user)"
echo "========================================="
${DOCKER} compose -f "${COMPOSE_FILE}" up airflow-init

echo "========================================="
echo "Starting Airflow services"
echo "========================================="
${DOCKER} compose -f "${COMPOSE_FILE}" up -d

echo "========================================="
echo "Airflow installation completed"
echo "========================================="

PUBLIC_IP=$(curl -s --connect-timeout 1 http://169.254.169.254/latest/meta-data/public-ipv4 || true)

echo "Access Airflow UI at:"
if [ -n "${PUBLIC_IP}" ]; then
  echo "http://${PUBLIC_IP}:8080"
else
  echo "http://<EC2_PUBLIC_IP>:8080"
fi

echo "Default credentials:"
echo "User: airflow"
echo "Password: airflow"

echo
echo "TIP:"
echo "- If you want docker without sudo in SSM, exit and re-enter the session."