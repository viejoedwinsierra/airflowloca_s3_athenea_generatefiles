#!/bin/bash
# ============================================================
# Destroy EC2 Infrastructure - AWS Academy
# Deletes:
#   - EC2 instance (by Name tag)
#   - Associated Security Group
# Region: us-east-1
# ============================================================

set -e

REGION="us-east-1"
INSTANCE_NAME="bd-airflow-ec2"
SECURITY_GROUP_NAME="bd-airflow-sg"

echo "==> Setting region to ${REGION}"
aws configure set region ${REGION}

echo "==> Searching for EC2 instance with Name=${INSTANCE_NAME}"

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
            "Name=instance-state-name,Values=running,stopped,pending,stopping" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

if [ -z "$INSTANCE_ID" ]; then
  echo "No instance found with Name=${INSTANCE_NAME}"
else
  echo "Instance found: ${INSTANCE_ID}"
  echo "==> Terminating instance..."
  aws ec2 terminate-instances --instance-ids ${INSTANCE_ID}

  echo "==> Waiting for instance termination..."
  aws ec2 wait instance-terminated --instance-ids ${INSTANCE_ID}

  echo "Instance terminated."
fi

echo "==> Searching for Security Group ${SECURITY_GROUP_NAME}"

SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${SECURITY_GROUP_NAME}" \
  --query "SecurityGroups[].GroupId" \
  --output text)

if [ -z "$SG_ID" ]; then
  echo "Security group not found."
else
  echo "Security Group found: ${SG_ID}"
  echo "==> Deleting Security Group..."
  aws ec2 delete-security-group --group-id ${SG_ID}
  echo "Security group deleted."
fi

echo "==> Infrastructure cleanup completed."
