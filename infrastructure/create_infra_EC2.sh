cat > create_infra_EC2.sh  <<EOF
#!/bin/bash
# ============================================================
# Create EC2 (Amazon Linux 2) for Airflow - AWS Academy
# Region: us-east-1
# Uses: LabInstanceProfile
# ============================================================

set -euo pipefail

REGION="us-east-1"
INSTANCE_TYPE="t3.small"
SECURITY_GROUP_NAME="bd-airflow-sg"
INSTANCE_NAME="bd-airflow-ec2-$(date +%Y%m%d-%H%M%S)"
KEY_NAME="${KEY_NAME:-}"   # opcional: export KEY_NAME=mi-keypair
MY_IP_CIDR="${MY_IP_CIDR:-0.0.0.0/0}"  # recomendado: export MY_IP_CIDR="TU_IP/32"

echo "==> Setting region to ${REGION}"
aws configure set region "${REGION}"

echo "==> Getting latest Amazon Linux 2 AMI (x86_64, HVM, gp2)"
AMI_ID=$(
  aws ec2 describe-images \
    --owners amazon \
    --filters \
      "Name=name,Values=amzn2-ami-hvm-2.0.*-x86_64-gp2" \
      "Name=state,Values=available" \
      "Name=architecture,Values=x86_64" \
      "Name=root-device-type,Values=ebs" \
      "Name=virtualization-type,Values=hvm" \
    --query "Images | sort_by(@,&CreationDate)[-1].ImageId" \
    --output text
)

if [[ -z "${AMI_ID}" || "${AMI_ID}" == "None" ]]; then
  echo "ERROR: No AMI found for Amazon Linux 2 in ${REGION}"
  exit 1
fi
echo "==> AMI_ID=${AMI_ID}"

echo "==> Getting default VPC"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)
if [[ -z "${VPC_ID}" || "${VPC_ID}" == "None" ]]; then
  echo "ERROR: Default VPC not found"
  exit 1
fi
echo "==> VPC_ID=${VPC_ID}"

echo "==> Ensuring security group ${SECURITY_GROUP_NAME}"
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${SECURITY_GROUP_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query "SecurityGroups[0].GroupId" --output text || true)

if [[ -z "${SG_ID}" || "${SG_ID}" == "None" ]]; then
  SG_ID=$(aws ec2 create-security-group \
    --group-name "${SECURITY_GROUP_NAME}" \
    --description "Security group for Airflow EC2 (SSH + 8080)" \
    --vpc-id "${VPC_ID}" \
    --query "GroupId" --output text)
  echo "==> Created SG_ID=${SG_ID}"
else
  echo "==> Found SG_ID=${SG_ID}"
fi

echo "==> Authorizing inbound rules (SSH 22, Airflow 8080) from ${MY_IP_CIDR}"
# SSH
aws ec2 authorize-security-group-ingress \
  --group-id "${SG_ID}" \
  --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MY_IP_CIDR},Description='SSH'}]" \
  >/dev/null 2>&1 || true

# Airflow webserver
aws ec2 authorize-security-group-ingress \
  --group-id "${SG_ID}" \
  --ip-permissions "IpProtocol=tcp,FromPort=8080,ToPort=8080,IpRanges=[{CidrIp=${MY_IP_CIDR},Description='Airflow Web'}]" \
  >/dev/null 2>&1 || true

echo "==> Selecting a subnet (default VPC)"
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
  --query "Subnets | sort_by(@,&AvailabilityZone)[0].SubnetId" \
  --output text)

if [[ -z "${SUBNET_ID}" || "${SUBNET_ID}" == "None" ]]; then
  # fallback: any subnet in the VPC
  SUBNET_ID=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "Subnets | sort_by(@,&AvailabilityZone)[0].SubnetId" \
    --output text)
fi
echo "==> SUBNET_ID=${SUBNET_ID}"

echo "==> Building run-instances command"
RUN_ARGS=(
  --image-id "${AMI_ID}"
  --count 1
  --instance-type "${INSTANCE_TYPE}"
  --security-group-ids "${SG_ID}"
  --subnet-id "${SUBNET_ID}"
  --iam-instance-profile Name=LabInstanceProfile
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]"
)

# KeyPair opcional para SSH. Si no la pasas, igual puedes usar SSM si el lab lo permite.
if [[ -n "${KEY_NAME}" ]]; then
  RUN_ARGS+=( --key-name "${KEY_NAME}" )
  echo "==> Using KEY_NAME=${KEY_NAME}"
else
  echo "==> KEY_NAME not set (no SSH key pair will be attached)"
fi

echo "==> Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances "${RUN_ARGS[@]}" --query "Instances[0].InstanceId" --output text)
echo "==> INSTANCE_ID=${INSTANCE_ID}"

echo "==> Waiting until instance is running..."
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}"

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
PUBLIC_DNS=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query "Reservations[0].Instances[0].PublicDnsName" --output text)

echo "==> Ready!"
echo "    Name: ${INSTANCE_NAME}"
echo "    InstanceId: ${INSTANCE_ID}"
echo "    Public IP: ${PUBLIC_IP}"
echo "    Public DNS: ${PUBLIC_DNS}"
echo "    Airflow URL (after install): http://${PUBLIC_IP}:8080"
EOF
ls -ltr
