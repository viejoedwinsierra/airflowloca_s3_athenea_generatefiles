#archivo para ejecitar
rm -f run_airflow_optionA.sh
cat > run_airflow_optionA.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# ===== CONFIGURACIÓN (Opción A) =====
PROJECT_DIR="${PROJECT_DIR:-$HOME/airflow-lite}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.lite.yaml}"
AIRFLOW_PORT="${AIRFLOW_PORT:-8080}"

log(){ printf "%s %s\n" "$(date -u +%FT%TZ)" "$*"; }
die(){ log "ERROR: $*"; exit 1; }
trap 'die "Fallo en línea ${BASH_LINENO[0]}: ${BASH_COMMAND}"' ERR

log "== Directorio del proyecto =="
log "${PROJECT_DIR}"

cd "${PROJECT_DIR}" 2>/dev/null || die "No existe ${PROJECT_DIR}"
[[ -f "${COMPOSE_FILE}" ]] || die "No existe ${PROJECT_DIR}/${COMPOSE_FILE}"

log "== Validando Docker =="
command -v docker >/dev/null 2>&1 || die "Docker no instalado"

if ! systemctl is-active docker >/dev/null 2>&1; then
  log "Iniciando docker..."
  sudo systemctl enable --now docker
fi

# ===== Resolver Compose (v2 plugin preferido) =====
log "== Validando Compose =="
NEED_SUDO=0
if ! docker ps >/dev/null 2>&1; then
  NEED_SUDO=1
  log "Docker requiere sudo en esta sesión"
fi

# Detectar compose v2 (docker compose) o v1 (docker-compose)
if [[ "$NEED_SUDO" -eq 0 ]] && docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif [[ "$NEED_SUDO" -eq 1 ]] && sudo -E env "PATH=$PATH" docker compose version >/dev/null 2>&1; then
  DC="sudo -E env \"PATH=$PATH\" docker compose"
elif [[ "$NEED_SUDO" -eq 0 ]] && command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
elif [[ "$NEED_SUDO" -eq 1 ]] && command -v docker-compose >/dev/null 2>&1; then
  # docker-compose existe pero docker requiere sudo → ejecutar con sudo (heredando PATH)
  DC="sudo -E env \"PATH=$PATH\" docker-compose"
else
  die "No se encontró 'docker compose' (v2) ni 'docker-compose' (v1)."
fi

log "Usando: ${DC}"

log "== Validando compose config =="
eval "${DC} -f \"${COMPOSE_FILE}\" config >/dev/null"
log "OK: compose válido"

# ===== Permisos Airflow (UID 50000) =====
log "== Ajustando permisos de logs/dags/plugins =="
ls -ld logs logs/scheduler 2>/dev/null || true

sudo mkdir -p logs dags plugins
sudo chown -R 50000:0 logs dags plugins
sudo chmod -R u+rwX,g+rX,o+rX logs dags plugins

log "== Ejecutando airflow-init =="
set +e
eval "${DC} -f \"${COMPOSE_FILE}\" up airflow-init"
INIT_RC=$?
set -e

if [[ "$INIT_RC" -ne 0 ]]; then
  log "ERROR en airflow-init"
  eval "${DC} -f \"${COMPOSE_FILE}\" logs --tail=200 airflow-init || true"
  exit "$INIT_RC"
fi

log "== Levantando servicios =="
eval "${DC} -f \"${COMPOSE_FILE}\" up -d"

log "== Estado de contenedores =="
eval "${DC} -f \"${COMPOSE_FILE}\" ps"

log "== Esperando health 200 =="
for i in $(seq 1 40); do
  CODE="$(curl -s -o /dev/null -w "%{http_code}" http://localhost:${AIRFLOW_PORT}/health || true)"
  if [[ "$CODE" == "200" ]]; then
    log "✅ OK: Airflow responde en puerto ${AIRFLOW_PORT}"
    exit 0
  fi
  sleep 2
done

log "WARN: No respondió 200. Mostrando logs webserver:"
eval "${DC} -f \"${COMPOSE_FILE}\" logs --tail=200 airflow-webserver || true"
exit 1
EOF

chmod +x run_airflow_optionA.sh
bash run_airflow_optionA.sh && echo "OK: syntax"
