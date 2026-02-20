#!/bin/bash

# ==============================================================
# Apache Airflow Installation via Docker
# AWS Academy Sandbox - Amazon Linux 2
# ==============================================================
# This script:
#   - Installs Docker
#   - Installs Docker Compose
#   - Downloads official Airflow docker-compose
#   - Initializes Airflow
#   - Starts Airflow services
# ==============================================================

set -e

echo "========================================="
echo "Updating system"
echo "========================================="
sudo yum update -y

echo "========================================="
echo "Installing Docker"
echo "========================================="
sudo amazon-linux-extras install docker -y
sudo service docker start
sudo usermod -aG docker ec2-user
sudo chkconfig docker on

echo "========================================="
echo "Installing Docker Compose plugin (if needed)"
echo "========================================="
if ! docker compose version >/dev/null 2>&1; then
  sudo mkdir -p /usr/libexec/docker/cli-plugins
  sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
    -o /usr/libexec/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/libexec/docker/cli-plugins/docker-compose
fi

echo "========================================="
echo "Creating Airflow project directory"
echo "========================================="
mkdir -p ~/airflow-docker/{dags,logs,plugins,config}
cd ~/airflow-docker

echo "========================================="
echo "Downloading official Airflow docker-compose file"
echo "========================================="
curl -LfO https://airflow.apache.org/docs/apache-airflow/stable/docker-compose.yaml

echo "========================================="
echo "Creating .env file"
echo "========================================="
sudo cat > .env <<EOF
AIRFLOW_IMAGE_NAME=apache/airflow:2.10.3
AIRFLOW_UID=50000
AIRFLOW_GID=0
EOF

echo "========================================="
echo "Initializing Airflow (creating database and user)"
echo "========================================="
sudo docker compose up airflow-init

echo "========================================="
echo "Starting Airflow services"
echo "========================================="
sudo docker compose up -d

echo "========================================="
echo "Airflow installation completed"
echo "========================================="

echo "Access Airflow UI at:"
echo "http://<EC2_PUBLIC_IP>:8080"

echo "Default credentials:"
echo "User: airflow"
echo "Password: airflow"
