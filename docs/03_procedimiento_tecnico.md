
# 🛠 Procedimiento Técnico Paso a Paso

## Crear Key Pair
aws ec2 create-key-pair --key-name airflow-key --query 'KeyMaterial' --output text > airflow-key.pem

## Crear Security Group
aws ec2 create-security-group --group-name airflow-sg --description "Airflow SG"

## Autorizar Puertos
aws ec2 authorize-security-group-ingress --group-name airflow-sg --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-name airflow-sg --protocol tcp --port 8080 --cidr 0.0.0.0/0

## Lanzar EC2
aws ec2 run-instances --image-id <AMI_ID> --instance-type t3.medium --key-name airflow-key --security-groups airflow-sg --count 1

## Conectarse
ssh -i airflow-key.pem ec2-user@<PUBLIC_IP>

## Instalar Docker
sudo dnf install docker -y
sudo systemctl start docker
sudo usermod -aG docker $USER
newgrp docker

## Ejecutar Airflow Lite
docker compose -f docker-compose.lite.yaml up airflow-init
docker compose -f docker-compose.lite.yaml up -d
