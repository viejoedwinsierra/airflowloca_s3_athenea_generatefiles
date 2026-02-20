#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# Defaults / Config
# =========================
AIRFLOW_HOME_DIR_DEFAULT="${HOME}/airflow-lite"
AIRFLOW_UID_DEFAULT="50000"
AIRFLOW_IMAGE_DEFAULT="apache/airflow:2.10.3"
AIRFLOW_PORT_DEFAULT="8080"
COMPOSE_PROJECT_DEFAULT="airflowlite"
LOG_DIR_DEFAULT="${HOME}/logs"

AIRFLOW_HOME_DIR="${AIRFLOW_HOME_DIR:-$AIRFLOW_HOME_DIR_DEFAULT}"
AIRFLOW_UID="${AIRFLOW_UID:-$AIRFLOW_UID_DEFAULT}"
AIRFLOW_IMAGE="${AIRFLOW_IMAGE:-$AIRFLOW_IMAGE_DEFAULT}"
AIRFLOW_PORT="${AIRFLOW_PORT:-$AIRFLOW_PORT_DEFAULT}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-$COMPOSE_PROJECT_DEFAULT}"
LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"

# Admin creds (no hardcode obligatorio)
AIRFLOW_ADMIN_USER="${AIRFLOW_ADMIN_USER:-admin}"
AIRFLOW_ADMIN_EMAIL="${AIRFLOW_ADMIN_EMAIL:-admin@example.com}"
AIRFLOW_ADMIN_PASSWORD="${AIRFLOW_ADMIN_PASSWORD:-}" # si vacío, se genera

DEBUG="${DEBUG:-0}"
DO_PULL="${DO_PULL:-0}"
FORCE="${FORCE:-0}"

# =========================
# Logging
# =========================
_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
_log(){ printf "%s [%s] %s\n" "$(_ts)" "$1" "$2"; }
info(){ _log "INFO" "$*"; }
warn(){ _log "WARN" "$*"; }
error(){ _log "ERROR" "$*"; }
debug(){ [[ "$DEBUG" == "1" ]] && _log "DEBUG" "$*" || true; }
die(){ error "$*"; exit 1; }

_on_err() {
  local ec=$?
  error "Fallo (exit=$ec) en línea ${BASH_LINENO[0]:-?}: ${BASH_COMMAND:-?}"
  exit "$ec"
}
trap _on_err ERR

# =========================
# Helpers
# =========================
have_cmd(){ command -v "$1" >/dev/null 2>&1; }
require_cmd(){ have_cmd "$1" || die "Falta comando requerido: $1"; }

run(){ local d="$1"; shift; info "$d"; debug "CMD: $*"; "$@"; }

sudo_run(){
  local d="$1"; shift
  if [[ "${EUID}" -eq 0 ]]; then run "$d" "$@"; else require_cmd sudo; run "$d" sudo "$@"; fi
}

detect_os(){
  [[ -r /etc/os-release ]] || die "No puedo leer /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
  echo "${NAME:-unknown}|${VERSION_ID:-unknown}"
}

is_amazon_linux(){
  local os; os="$(detect_os)"
  [[ "$os" == Amazon\ Linux* ]]
}

arch(){ uname -m; }

docker_daemon_ok(){ docker info >/dev/null 2>&1; }

docker_run(){
  if docker_daemon_ok; then docker "$@"; else sudo docker "$@"; fi
}

compose_run(){
  if docker_run compose version >/dev/null 2>&1; then
    docker_run compose "$@"
  elif have_cmd docker-compose; then
    if docker_daemon_ok; then docker-compose "$@"; else sudo docker-compose "$@"; fi
  else
    die "No hay Docker Compose disponible (docker compose / docker-compose)."
  fi
}

# =========================
# Checks
# =========================
check_network_basic(){
  if have_cmd curl; then
    curl -fsS --max-time 5 https://registry-1.docker.io/v2/ >/dev/null 2>&1 \
      && info "Conectividad a Docker Hub OK." \
      || warn "No pude validar conectividad a Docker Hub (pull puede fallar)."
  else
    warn "curl no está disponible para validar conectividad."
  fi
}

check_port_free(){
  local port="$1"
  require_cmd ss
  # check simple y portable
  if ss -lnt | awk '{print $4}' | grep -E "(:|\\.)${port}\$" -q; then
    die "El puerto ${port} ya está en uso. Cambia AIRFLOW_PORT o libera el puerto."
  fi
}

# =========================
# Install Docker/Compose (AL2)
# =========================
ensure_packages(){
  local pkgs=(curl ca-certificates)
  have_cmd ss || pkgs+=(iproute)
  sudo_run "Instalando paquetes base (si faltan)..." yum install -y "${pkgs[@]}"
}

ensure_docker_al2(){
  if have_cmd docker; then
    info "Docker ya instalado: $(docker --version || true)"
  else
    info "Instalando Docker (AL2)..."
    if have_cmd amazon-linux-extras; then
      sudo_run "amazon-linux-extras install docker..." amazon-linux-extras install docker -y
    else
      sudo_run "yum install docker..." yum install -y docker
    fi
  fi

  sudo_run "Habilitando e iniciando docker.service..." systemctl enable --now docker

  [[ -S /var/run/docker.sock ]] || die "No existe /var/run/docker.sock. Docker daemon no está listo."

  if docker_daemon_ok; then
    info "Docker daemon OK sin sudo."
  else
    warn "Docker requiere sudo en esta sesión (grupo docker no aplicado). Seguiré con fallback a sudo."
    sudo docker info >/dev/null 2>&1 || die "Docker daemon no responde ni con sudo."
  fi
}

ensure_docker_group(){
  if getent group docker >/dev/null 2>&1; then
    info "Grupo docker existe."
  else
    sudo_run "Creando grupo docker..." groupadd docker
  fi

  if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    info "Usuario $USER ya está en grupo docker."
  else
    sudo_run "Agregando $USER a grupo docker..." usermod -aG docker "$USER"
    warn "Debes reconectar la sesión SSM para aplicar grupo docker (o seguirás usando sudo)."
  fi
}

ensure_compose(){
  if docker_run compose version >/dev/null 2>&1; then
    info "Compose OK: $(docker_run compose version | head -n1)"
    return 0
  fi

  warn "No existe 'docker compose'. Intentaré instalar docker-compose-plugin..."
  if sudo yum install -y docker-compose-plugin >/dev/null 2>&1; then
    info "docker-compose-plugin instalado."
  else
    warn "No pude instalar docker-compose-plugin por yum. Haré fallback binario."
    local a url
    a="$(arch)"
    case "$a" in
      x86_64) url="https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-linux-x86_64" ;;
      aarch64|arm64) url="https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-linux-aarch64" ;;
      *) die "Arquitectura no soportada: $a" ;;
    esac
    sudo_run "Descargando docker-compose..." curl -fsSL "$url" -o /usr/local/bin/docker-compose
    sudo_run "chmod +x docker-compose..." chmod +x /usr/local/bin/docker-compose
  fi

  docker_run compose version >/dev/null 2>&1 || have_cmd docker-compose || die "Compose no quedó instalado."
}

# =========================
# Airflow stack
# =========================
gen_password(){
  # password razonable y portable
  if have_cmd openssl; then
    openssl rand -base64 18 | tr -d '\n'
  else
    date +%s%N | sha256sum | awk '{print substr($1,1,18)}'
  fi
}

ensure_dirs(){
  mkdir -p "$AIRFLOW_HOME_DIR"/{dags,logs,plugins,data,config} "$LOG_DIR"
  # Evitar bug del bind: crear archivo airflow.db explícito
  [[ -f "$AIRFLOW_HOME_DIR/airflow.db" ]] || touch "$AIRFLOW_HOME_DIR/airflow.db"
  sudo_run "Alineando ownership UID=${AIRFLOW_UID}..." chown -R "${AIRFLOW_UID}:0" \
    "$AIRFLOW_HOME_DIR/dags" "$AIRFLOW_HOME_DIR/logs" "$AIRFLOW_HOME_DIR/plugins" \
    "$AIRFLOW_HOME_DIR/data" "$AIRFLOW_HOME_DIR/config" "$AIRFLOW_HOME_DIR/airflow.db"
  run "Permisos mínimos en directorio..." chmod -R u=rwX,g=rX,o=rX "$AIRFLOW_HOME_DIR"
}

write_env(){
  local env_file="$AIRFLOW_HOME_DIR/.env"
  if [[ -f "$env_file" && "$FORCE" != "1" ]]; then
    info ".env existe, no se sobreescribe."
    return 0
  fi

  if [[ -z "$AIRFLOW_ADMIN_PASSWORD" ]]; then
    AIRFLOW_ADMIN_PASSWORD="$(gen_password)"
    warn "AIRFLOW_ADMIN_PASSWORD no estaba definido. Se generó uno (se mostrará al final)."
  fi

  cat > "$env_file" <<EOF
AIRFLOW_UID=${AIRFLOW_UID}
AIRFLOW_IMAGE=${AIRFLOW_IMAGE}
AIRFLOW_PORT=${AIRFLOW_PORT}
AIRFLOW_ADMIN_USER=${AIRFLOW_ADMIN_USER}
AIRFLOW_ADMIN_EMAIL=${AIRFLOW_ADMIN_EMAIL}
AIRFLOW_ADMIN_PASSWORD=${AIRFLOW_ADMIN_PASSWORD}
EOF
  chmod 600 "$env_file"
  info ".env escrito: $env_file"
}

write_compose(){
  local f="$AIRFLOW_HOME_DIR/docker-compose.yml"
  if [[ -f "$f" && "$FORCE" != "1" ]]; then
    info "docker-compose.yml existe, no se sobreescribe."
    return 0
  fi

  cat > "$f" <<'YAML'
services:
  airflow-init:
    image: ${AIRFLOW_IMAGE}
    container_name: airflow-init
    env_file: .env
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
    entrypoint: /bin/bash
    command:
      - -c
      - |
        set -euo pipefail
        airflow db migrate
        airflow users create \
          --username "${AIRFLOW_ADMIN_USER}" \
          --firstname Admin \
          --lastname User \
          --role Admin \
          --email "${AIRFLOW_ADMIN_EMAIL}" \
          --password "${AIRFLOW_ADMIN_PASSWORD}" || true
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
      # Sin curl: usa python stdlib (más estable en imagen Airflow)
      test: ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8080/health').read()\" >/dev/null 2>&1 || exit 1"]
      interval: 15s
      timeout: 8s
      retries: 30
      start_period: 35s

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

  info "docker-compose.yml escrito: $f"
}

validate(){
  info "Validando docker..."
  docker_run version >/dev/null
  docker_run info >/dev/null

  info "Validando compose..."
  (cd "$AIRFLOW_HOME_DIR" && compose_run -p "$COMPOSE_PROJECT" config >/dev/null)

  info "Validando puerto..."
  require_cmd ss
  ss -lnt | awk '{print $4}' | grep -E "(:|\\.)${AIRFLOW_PORT}\$" -q \
    && info "Puerto ${AIRFLOW_PORT} listening." \
    || warn "Puerto ${AIRFLOW_PORT} NO listening aún."

  info "Validando /health..."
  local code=""
  for i in {1..40}; do
    code="$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${AIRFLOW_PORT}/health" || true)"
    [[ "$code" == "200" ]] && break
    sleep 2
  done
  [[ "$code" == "200" ]] || die "/health no respondió 200 (último código: $code)."

  info "Contenedores:"
  (cd "$AIRFLOW_HOME_DIR" && compose_run -p "$COMPOSE_PROJECT" ps)

  info "DB check:"
  docker_run exec airflow-webserver airflow db check || warn "airflow db check falló (revisar logs)."

  info "Validate OK."
}

up(){
  check_port_free "$AIRFLOW_PORT"
  (cd "$AIRFLOW_HOME_DIR" && compose_run -p "$COMPOSE_PROJECT" up -d)
  validate
}

down(){
  (cd "$AIRFLOW_HOME_DIR" && compose_run -p "$COMPOSE_PROJECT" down)
}

logs(){
  local svc="${1:-}"
  [[ -n "$svc" ]] || die "Uso: $0 logs <airflow-webserver|airflow-scheduler|airflow-init>"
  (cd "$AIRFLOW_HOME_DIR" && compose_run -p "$COMPOSE_PROJECT" logs -f "$svc")
}

summary(){
  local ip
  ip="$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || true)"
  info "Airflow Home: $AIRFLOW_HOME_DIR"
  info "URL: http://${ip:-<ip_de_la_instancia>}:${AIRFLOW_PORT}"
  info "User: ${AIRFLOW_ADMIN_USER}"
  if [[ -n "$AIRFLOW_ADMIN_PASSWORD" ]]; then
    warn "Password: ${AIRFLOW_ADMIN_PASSWORD}"
  else
    warn "Password no disponible aquí (lee $AIRFLOW_HOME_DIR/.env)."
  fi
}

usage(){
  cat <<EOF
Uso:
  $0 install            # paquetes + docker + compose + grupo docker
  $0 init               # dirs + env + compose (no levanta)
  $0 up [--pull]        # levanta stack (opcional pull)
  $0 validate           # validaciones post deploy
  $0 down               # baja stack
  $0 logs <service>     # logs follow
Variables:
  AIRFLOW_HOME_DIR, AIRFLOW_UID, AIRFLOW_IMAGE, AIRFLOW_PORT, COMPOSE_PROJECT
  AIRFLOW_ADMIN_USER, AIRFLOW_ADMIN_EMAIL, AIRFLOW_ADMIN_PASSWORD
Flags:
  FORCE=1 sobrescribe env/compose
  DO_PULL=1 hace pull antes de up
  DEBUG=1 logs debug
EOF
}

main(){
  local cmd="${1:-}"
  shift || true

  is_amazon_linux || die "Este script es para Amazon Linux. Detectado: $(detect_os)"
  ensure_packages
  check_network_basic

  case "$cmd" in
    install)
      ensure_docker_al2
      ensure_docker_group
      ensure_compose
      ;;
    init)
      ensure_dirs
      write_env
      write_compose
      ;;
    up)
      ensure_dirs
      write_env
      write_compose
      if [[ "$DO_PULL" == "1" ]]; then
        (cd "$AIRFLOW_HOME_DIR" && compose_run -p "$COMPOSE_PROJECT" pull)
      fi
      up
      summary
      ;;
    validate) validate ;;
    down) down ;;
    logs) logs "${1:-}" ;;
    *) usage ;;
  esac
}

main "$@"
