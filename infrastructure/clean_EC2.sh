cat > destroy_infra_EC2.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

REGION="us-east-1"
INSTANCE_NAME_PREFIX="bd-airflow-ec2"
SECURITY_GROUP_NAME="bd-airflow-sg"

echo "==> Region: ${REGION}"
export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"

echo "==> Searching instances with Name=${INSTANCE_NAME_PREFIX}*"
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${INSTANCE_NAME_PREFIX}*" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

if [[ -z "${INSTANCE_IDS}" || "${INSTANCE_IDS}" == "None" ]]; then
  echo "No instances found with Name=${INSTANCE_NAME_PREFIX}*"
else
  echo "Found instances: ${INSTANCE_IDS}"
  echo "==> Terminating..."
  aws ec2 terminate-instances --instance-ids ${INSTANCE_IDS} >/dev/null

  echo "==> Waiting for termination..."
  aws ec2 wait instance-terminated --instance-ids ${INSTANCE_IDS}

  echo "✅ Instances terminated."
fi

echo "==> Searching Security Group ${SECURITY_GROUP_NAME}"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${SECURITY_GROUP_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)

if [[ -z "${SG_ID}" || "${SG_ID}" == "None" ]]; then
  echo "No Security Group found: ${SECURITY_GROUP_NAME}"
  exit 0
fi

echo "Found SG_ID=${SG_ID}"

# Importante: si SG está en uso por ENIs, fallará. Aquí lo intentamos y si falla, mostramos el motivo.
echo "==> Deleting Security Group..."
if aws ec2 delete-security-group --group-id "${SG_ID}" 2>/tmp/sg_delete_err.txt; then
  echo "✅ Security Group deleted."
else
  echo "⚠️  No se pudo borrar el SG (probablemente aún en uso). Detalle:"
  cat /tmp/sg_delete_err.txt
  echo
  echo "Sugerencia: valida si hay ENIs usando el SG:"
  echo "aws ec2 describe-network-interfaces --filters Name=group-id,Values=${SG_ID} --query 'NetworkInterfaces[].NetworkInterfaceId' --output text"
fi
EOF

chmod +x destroy_infra_EC2.sh
./destroy_infra_EC2.sh
