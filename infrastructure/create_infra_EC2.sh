#!/bin/bash
# ============================================================
# Create EC2 (Amazon Linux 2) for Airflow - AWS Academy
# Region: us-east-1 (adjust if needed)
# Uses: LabInstanceProfile
# ============================================================

set -e

REGION="us-east-1"
INSTANCE_TYPE="t3.small"
SECURITY_GROUP_NAME="bd-airflow-sg"
INSTANCE_NAME="bd-airflow-ec2-$date"

echo "==> Setting region to ${REGION}"
aws configure set region ${REGION}

echo "==> Getting latest Amazon Linux 2 AMI"
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --output text)

echo "AMI: ${AMI_ID}"

echo "==> Creating Security Group"
SG_ID=$(aws ec2 create-security-group \
  --group-name ${SECURITY_GROUP_NAME} \
  --description "SG for Airflow EC2" \
  --query "GroupId" \
  --output text)

echo "SG: ${SG_ID}"

echo "==> Authorizing inbound ports (22, 8080)"
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} \
  --protocol tcp --port 22 --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} \
  --protocol tcp --port 8080 --cidr 0.0.0.0/0

echo "==> Launching EC2 with LabInstanceProfile"
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id ${AMI_ID} \
  --instance-type ${INSTANCE_TYPE} \
  --iam-instance-profile Name=LabInstanceProfile \
  --security-group-ids ${SG_ID} \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
  --count 1 \
  --query "Instances[0].InstanceId" \
  --output text)

echo "Instance ID: ${INSTANCE_ID}"

echo "==> Waiting until instance is running..."
aws ec2 wait instance-running --instance-ids ${INSTANCE_ID}

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids ${INSTANCE_ID} \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

echo "Public IP: ${PUBLIC_IP}"

echo "==> Done."
echo "Connect via SSM (recommended):"
echo "aws ssm start-session --target ${INSTANCE_ID}"
