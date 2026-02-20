#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# Configuración (editable)
# =========================
AIRFLOW_HOME_DIR_DEFAULT="${HOME}/airflow-lite"
AIRFLOW_UID_DEFAULT="50000"
AIRFLOW_IMAGE_DEFAULT="apache/airflow:2.10.3"
AIRFLOW_PORT_DEFAULT="8080"
COMPOSE_PROJECT_DEFAULT="airflowlite"
LOG_DIR_DEFAULT="${HOME}/logs"
LOG_FILE_DEFAULT=""   # si vacío, solo stdout

# Permite sobreescritura por env:
AIRFLOW_HOME_DIR="${AIRFLOW_HOME_DIR:-$AIRFLOW_HOME_DIR_DEFAULT}"
AIRFLOW_UID="${AIRFLOW_UID:-$AIRFLOW_UID_DEFAULT}"
AIRFLOW_IMAGE="${AIRFLOW_IMAGE:-$AIRFLOW_IMAGE_DEFAULT}"
AIRFLOW_PORT="${AIRFLOW_PORT:-$AIRFLOW_PORT_DEFAULT}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-$COMPOSE_PROJECT_DEFAULT}"
LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"
LOG_FILE="${LOG_FILE:-$LOG_FILE_DEFAULT}"

# =========================
# Logging
# =========================
_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
_log() {
  local level="$1"; shift
  local msg="$*"
  if [[ -n "${LOG_FILE}" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf "%s [%s] %s\n" "$(_ts)" "$level" "$msg" | tee -a "$LOG_FILE"
  else
    printf "%s [%s] %s\n" "$(_ts)" "$level" "$msg"
  fi
}
info(){ _log "INFO" "$*"; }
warn(){ _log "WARN" "$*"; }
error(){ _log "ERROR" "$*"; }
debug(){ [[ "${DEBUG:-0}" == "1" ]] && _log "DEBUG" "$*" || true; }

die(){
  error "$*"
  exit 1
}

# Reporte de error con contexto
_on_err() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-unknown}
  local cmd=${BASH_COMMAND:-unknown}
  error "Fallo en línea ${line_no} (exit=${exit_code}): ${cmd}"
  exit "$exit_code"
}
trap _on_err ERR

# =========================
# Helpers
# =========================
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Falta comando requerido: $1"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run() {
  local desc="$1"; shift
  info "$desc"
  debug "CMD: $*"
  "$@"
}

need_sudo() {
  # No asume root. Detecta si es necesario sudo.
  if [[ "${EUID}" -eq 0 ]]; then
    return 1 # no necesita sudo
  fi
  return 0
}

sudo_run() {
  local desc="$1"; shift
  if [[ "${EUID}" -eq 0 ]]; then
    run "$desc" "$@"
  else
    require_cmd sudo
    run "$desc" sudo "$@"
  fi
}

detect_os() {
  [[ -r /etc/os-release ]] || die "No puedo leer /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
  echo "${NAME:-unknown}|${VERSION_ID:-unknown}"
}

is_amazon_linux() {
  local os
  os="$(detect_os)"
  [[ "$os" == Amazon\ Linux* ]] || return 1
  return 0
}

is_al2() {
  local os
  os="$(detect_os)"
  # Amazon Linux 2 suele tener VERSION_ID="2"
  [[ "$os" == *"|2" ]] || return 1
  return 0
}

arch() {
  uname -m
}

check_network_basic() {
  # Validación simple de salida a internet / DNS.
  # No “bloquea” si falla, pero avisa porque afectará pulls.
  if have_cmd curl; then
    if curl -fsS --max-time 5 https://registry-1.docker.io/v2/ >/dev/null 2>&1; then
      info "Conectividad básica OK (Docker Hub reachable)."
    else
      warn "No pude validar conectividad con Docker Hub. El pull de imágenes puede fallar (DNS/NAT/SG)."
    fi
  else
    warn "curl no disponible para validar conectividad."
  fi
}

check_port_free() {
  local port="$1"
  require_cmd ss
  if ss -lnt "( sport = :$port )" | grep -q ":$port"; then
    die "El puerto $port ya está en uso. Libéralo o cambia AIRFLOW_PORT."
  fi
}

ensure_packages() {
  # Minimiza instalación: solo paquetes necesarios
  local pkgs=(curl ca-certificates)
  if ! have_cmd ss; then
    pkgs+=(iproute)
  fi
  if ! have_cmd jq; then
    # jq es útil para health JSON, pero no obligatorio
    warn "jq no está instalado; continuaré sin parseo JSON avanzado."
  fi

  if need_sudo; then
    sudo_run "Instalando paquetes base requeridos (si faltan)..." yum install -y "${pkgs[@]}"
  else
    run "Instalando paquetes base requeridos (si faltan)..." yum install -y "${pkgs[@]}"
  fi
}

# =========================
# Docker (AL2)
# =========================
docker_client_ok() {
  docker version >/dev/null 2>&1
}

docker_daemon_ok() {
  docker info >/dev/null 2>&1
}

ensure_docker_installed_al2() {
  if have_cmd docker; then
    info "Docker ya está instalado: $(docker --version || true)"
  else
    info "Docker no está instalado; procederé a instalarlo (AL2)."
    # Método preferente (si existe amazon-linux-extras), sino fallback yum.
    if have_cmd amazon-linux-extras; then
      sudo_run "Instalando Docker vía amazon-linux-extras..." amazon-linux-extras install docker -y
    else
      sudo_run "Instalando Docker vía yum..." yum install -y docker
    fi
  fi

  # Servicio
  sudo_run "Habilitando e iniciando docker.service..." systemctl enable --now docker

  # Socket
  if [[ ! -S /var/run/docker.sock ]]; then
    warn "No veo el socket /var/run/docker.sock. Revisaré estado del servicio..."
    sudo_run "Estado de docker.service" systemctl --no-pager status docker || true
    die "Docker daemon no está exponiendo el socket. No puedo continuar."
  fi

  # Probar daemon
  if docker_daemon_ok; then
    info "Docker daemon OK (docker info funciona)."
  else
    warn "docker info falló sin sudo. Intentaré con sudo..."
    if sudo docker info >/dev/null 2>&1; then
      warn "Docker funciona con sudo, pero no con tu usuario actual (permisos/grupo). Continuaré con fallback a sudo donde aplique."
    else
      die "Docker daemon no responde ni con sudo. Revisa systemctl status docker, logs y permisos."
    fi
  fi
}

# =========================
# Docker Compose v2
# =========================
compose_cmd() {
  # Preferimos "docker compose" (plugin v2)
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
    return 0
  fi
  # Fallback: docker-compose (binario)
  if have_cmd docker-compose; then
    echo "docker-compose"
    return 0
  fi
  return 1
}

ensure_compose_v2() {
  if docker compose version >/dev/null 2>&1; then
    info "Docker Compose v2 OK: $(docker compose version | head -n 1)"
    return 0
  fi

  warn "docker compose no disponible. Intentaré instalar plugin compose v2 en AL2."
  # En AL2, docker-compose-plugin suele existir en repos docker/amazon extras dependiendo config.
  # Intentar yum:
  if sudo yum install -y docker-compose-plugin >/dev/null 2>&1; then
    info "docker-compose-plugin instalado."
  else
    warn "No pude instalar docker-compose-plugin por yum. Intentaré instalar docker-compose standalone (fallback)."
    # Fallback binario oficial (más delicado: requiere URL correcta por arch)
    local a; a="$(arch)"
    local url=""
    case "$a" in
      x86_64) url="https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-linux-x86_64" ;;
      aarch64|arm64) url="https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-linux-aarch64" ;;
      *) die "Arquitectura no soportada para fallback compose: $a" ;;
    esac
    sudo_run "Descargando docker-compose standalone..." curl -fsSL "$url" -o /usr/local/bin/docker-compose
    sudo_run "Haciendo ejecutable docker-compose..." chmod +x /usr/local/bin/docker-compose
  fi

  # Validar
  if docker compose version >/dev/null 2>&1; then
    info "Docker Compose v2 OK: $(docker compose version | head -n 1)"
  elif have_cmd docker-compose; then
    info "docker-compose OK (fallback): $(docker-compose version | head -n 1)"
  else
    die "No pude habilitar docker compose v2 ni docker-compose."
  fi
}

# =========================
# Permisos docker (sin asumir root)
# =========================
ensure_docker_group_membership() {
  # Grupo docker existe?
  if getent group docker >/dev/null 2>&1; then
    info "Grupo 'docker' existe."
  else
    sudo_run "Creando grupo docker..." groupadd docker
  fi

  # Usuario pertenece?
  if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    info "Usuario $USER ya pertenece al grupo docker."
  else
    sudo_run "Agregando usuario $USER al grupo docker..." usermod -aG docker "$USER"
    warn "Se agregó $USER al grupo docker, pero NO aplica a esta sesión actual."
    warn "Recomendado: cerrar sesión y volver a entrar (SSM Session Manager: desconectar y reconectar)."
  fi

  # Validar si docker funciona sin sudo (en esta sesión)
  if docker_daemon_ok; then
    info "Docker usable sin sudo en esta sesión."
  else
    warn "Docker aún no funciona sin sudo en esta sesión. Continuaré usando sudo para operaciones docker donde sea necesario."
  fi
}

docker_run() {
  # Ejecuta docker con sudo si hace falta
  if docker_daemon_ok; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

compose_run() {
  local c
  if c="$(compose_cmd)"; then
    # shellcheck disable=SC2086
    if [[ "$c" == "docker compose" ]]; then
      if docker_daemon_ok; then
        docker compose "$@"
      else
        sudo docker compose "$@"
      fi
    else
      if docker_daemon_ok; then
        docker-compose "$@"
      else
        sudo docker-compose "$@"
      fi
    fi
  else
    die "No hay comando compose disponible."
  fi
}

# =========================
# Airflow Lite (Compose)
# =========================
ensure_dirs_and_env() {
  mkdir -p "$AIRFLOW_HOME_DIR"/{dags,logs,plugins,data,config} "$LOG_DIR"

  local env_file="$AIRFLOW_HOME_DIR/.env"
  if [[ -f "$env_file" ]]; then
    info "Archivo .env ya existe: $env_file (no lo sobreescribo)."
  else
    info "Creando .env (permisos 0600) con AIRFLOW_UID=${AIRFLOW_UID}..."
    cat > "$env_file" <<EOF
AIRFLOW_UID=${AIRFLOW_UID}
AIRFLOW_IMAGE=${AIRFLOW_IMAGE}
AIRFLOW_PORT=${AIRFLOW_PORT}
EOF
    chmod 600 "$env_file"
  fi

  # Alineación UID para volúmenes (solo rutas del proyecto)
  # Nota: requiere sudo para chown a UID numérico si no es tu usuario.
  sudo_run "Alineando ownership de volúmenes a UID=${AIRFLOW_UID}..." chown -R "${AIRFLOW_UID}:0" \
    "$AIRFLOW_HOME_DIR/dags" \
    "$AIRFLOW_HOME_DIR/logs" \
    "$AIRFLOW_HOME_DIR/plugins" \
    "$AIRFLOW_HOME_DIR/data" \
    "$AIRFLOW_HOME_DIR/config"

  # Permisos mínimos razonables
  run "Aplicando permisos mínimos a directorios..." chmod -R u=rwX,g=rX,o=rX "$AIRFLOW_HOME_DIR"
}

write_compose_file() {
  local compose_file="$AIRFLOW_HOME_DIR/docker-compose.yml"

  if [[ -f "$compose_file" ]]; then
    info "docker-compose.yml ya existe: $compose_file (no lo sobreescribo)."
    return 0
  fi

  info "Creando docker-compose.yml (Airflow Lite SequentialExecutor)..."
  cat > "$compose_file" <<'YAML'
services:
  airflow-init:
    image: ${AIRFLOW_IMAGE}
    container_name: airflow-init
    env_file: .env
    environment:
      - AIRFLOW__CORE__EXECUTOR=SequentialExecutor
      - AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=sqlite:////opt/airflow/airflow.db
      - AIRFLOW__CORE__LOAD_EXAMPLES=False
      - _PIP_ADDITIONAL_REQUIREMENTS=
    user: "${AIRFLOW_UID}:0"
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
      - ./data:/opt/airflow/data
      - ./config:/opt/airflow/config
      - ./airflow.db:/opt/airflow/airflow.db
    entrypoint: /bin/bash
    command:
      - -c
      - |
        set -euo pipefail
        echo "[airflow-init] Migrating DB..."
        airflow db migrate
        echo "[airflow-init] Creating admin user if not exists..."
        airflow users create \
          --username admin \
          --firstname Admin \
          --lastname User \
          --role Admin \
          --email admin@example.com \
          --password admin || true
        echo "[airflow-init] Done."
    restart: "no"

  airflow-webserver:
    image: ${AIRFLOW_IMAGE}
    container_name: airflow-webserver
    env_file: .env
    depends_on:
      airflow-init:
        condition: service_completed_successfully
    environment:
      - AIRFLOW__CORE__EXECUTOR=SequentialExecutor
      - AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=sqlite:////opt/airflow/airflow.db
      - AIRFLOW__CORE__LOAD_EXAMPLES=False
      - AIRFLOW__WEBSERVER__EXPOSE_CONFIG=True
    user: "${AIRFLOW_UID}:0"
    ports:
      - "${AIRFLOW_PORT}:8080"
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
      - ./data:/opt/airflow/data
      - ./config:/opt/airflow/config
      - ./airflow.db:/opt/airflow/airflow.db
    command: webserver
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:8080/health >/dev/null || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 20
      start_period: 30s

  airflow-scheduler:
    image: ${AIRFLOW_IMAGE}
    container_name: airflow-scheduler
    env_file: .env
    depends_on:
      airflow-init:
        condition: service_completed_successfully
    environment:
      - AIRFLOW__CORE__EXECUTOR=SequentialExecutor
      - AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=sqlite:////opt/airflow/airflow.db
      - AIRFLOW__CORE__LOAD_EXAMPLES=False
    user: "${AIRFLOW_UID}:0"
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
      - ./data:/opt/airflow/data
      - ./config:/opt/airflow/config
      - ./airflow.db:/opt/airflow/airflow.db
    command: scheduler
    restart: unless-stopped
YAML

  info "docker-compose.yml creado: $compose_file"
}

validate_compose_config() {
  info "Validando sintaxis/expansión del compose..."
  (cd "$AIRFLOW_HOME_DIR" && compose_run -p "$COMPOSE_PROJECT" config >/dev/null)
}

pull_images() {
  info "Haciendo pull de imágenes (si no existen localmente)..."
  (cd "$AIRFLOW_HOME_DIR" && compose_run -p "$COMPOSE_PROJECT" pull)
}

up_airflow() {
  info "Levantando stack Airflow..."
  (cd "$AIRFLOW_HOME_DIR" && compose_run -p "$COMPOSE_PROJECT" up -d)
}

post_deploy_validations() {
  info "==== Validaciones post-deploy ===="

  info "Docker version:"
  docker_run version

  info "Docker info (resumen):"
  docker_run info >/dev/null && info "docker info OK" || die "docker info falló"

  info "Compose version:"
  if docker_run compose version >/dev/null 2>&1; then
    docker_run compose version | head -n 1
  elif have_cmd docker-compose; then
    docker_run compose version >/dev/null 2>&1 || true
    docker-compose version | head -n 1
  else
    die "No puedo obtener versión de compose"
  fi

  require_cmd ss
  info "Validando puerto ${AIRFLOW_PORT}..."
  if ! ss -lnt "( sport = :${AIRFLOW_PORT} )" | grep -q ":${AIRFLOW_PORT}"; then
    die "Puerto ${AIRFLOW_PORT} no está escuchando. Revisa webserver."
  fi
  info "Puerto ${AIRFLOW_PORT} OK (listening)."

  info "Estado de contenedores:"
  (cd "$AIRFLOW_HOME_DIR" && compose_run -p "$COMPOSE_PROJECT" ps)

  info "Esperando health del webserver..."
  local code=""
  for i in {1..30}; do
    code="$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${AIRFLOW_PORT}/health" || true)"
    if [[ "$code" == "200" ]]; then
      info "Health endpoint OK (200)."
      break
    fi
    sleep 2
  done
  [[ "$code" == "200" ]] || die "Health endpoint no respondió 200. Último código: ${code}"

  info "Validación scheduler (contenedor up):"
  local sched_state
  sched_state="$(docker_run inspect -f '{{.State.Status}}' airflow-scheduler 2>/dev/null || true)"
  [[ "$sched_state" == "running" ]] || die "Scheduler no está running (estado=${sched_state})."

  info "Validación DB (SQLite) dentro del contenedor webserver..."
  docker_run exec airflow-webserver airflow db check || warn "airflow db check falló (revisar logs)."

  info "Validaciones completadas."
}

print_summary() {
  cat <<EOF

==================== RESUMEN ====================
Airflow Home:     ${AIRFLOW_HOME_DIR}
Compose Project:  ${COMPOSE_PROJECT}
Airflow Image:    ${AIRFLOW_IMAGE}
Airflow UID:      ${AIRFLOW_UID}
Web URL:          http://<EC2_PUBLIC_OR_PRIVATE_IP>:${AIRFLOW_PORT}
Login:            admin / admin   (si el create user no cambió)
=================================================

Comandos útiles:
  cd "${AIRFLOW_HOME_DIR}"
  $(compose_cmd) -p "${COMPOSE_PROJECT}" ps
  $(compose_cmd) -p "${COMPOSE_PROJECT}" logs -f airflow-webserver
  $(compose_cmd) -p "${COMPOSE_PROJECT}" logs -f airflow-scheduler
  $(compose_cmd) -p "${COMPOSE_PROJECT}" down

EOF
}

main() {
  info "Iniciando instalación Airflow Lite en Amazon Linux..."
  is_amazon_linux || die "Este script está pensado para Amazon Linux. Detectado: $(detect_os)"
  if is_al2; then
    info "Detectado Amazon Linux 2."
  else
    warn "No parece AL2 (detectado: $(detect_os)). Ajusta rutas/instalación si es AL2023."
  fi

  ensure_packages
  check_network_basic

  # Validación puerto antes de levantar
  check_port_free "$AIRFLOW_PORT"

  # Docker + Compose
  ensure_docker_installed_al2
  ensure_docker_group_membership
  ensure_compose_v2

  # Airflow
  ensure_dirs_and_env
  write_compose_file
  validate_compose_config
  pull_images
  up_airflow
  post_deploy_validations
  print_summary
}

main "$@"
