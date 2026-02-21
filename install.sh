#!/usr/bin/env bash
set -euo pipefail

APP="triangels-tg-bridge"
ROOT_DIR="/opt/triangels"
CFG_DIR="${ROOT_DIR}/etc"

NAME="triangels-mtproxy"
PORT_DEFAULT="8443"
IMAGE_DEFAULT="nineseconds/mtg:2"

cfg_path() { echo "${CFG_DIR}/mtproxy.env"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

require() {
  if ! have "$1"; then
    echo "Missing dependency: $1"
    exit 1
  fi
}

ensure_docker() {
  if have docker; then
    return 0
  fi

  echo "Docker not found. Installing Docker..."

  if have apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker

    echo "Docker installed."
    return 0
  fi

  echo "Docker is missing and auto-install is not supported on this OS."
  exit 1
}

public_ip_guess() {
  ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1
}

ensure_dirs() {
  install -d -m 0755 "${ROOT_DIR}" "${CFG_DIR}" "${ROOT_DIR}/bin" "${ROOT_DIR}/logs" "${ROOT_DIR}/state"
}

ensure_cfg() {
  if [[ ! -f "$(cfg_path)" ]]; then
    umask 077
    local secret
    # MTProxy secret: dd + 16 bytes hex
    secret="$(printf 'dd%s' "$(openssl rand -hex 16)")"

    cat > "$(cfg_path)" <<CFG
PORT=${PORT_DEFAULT}
IMAGE=${IMAGE_DEFAULT}
SECRET=${secret}
CFG

    echo "Created config: $(cfg_path)"
  fi
}

load_cfg() {
  # shellcheck disable=SC1090
  source "$(cfg_path)"
}

docker_start() {
  ensure_dirs
  ensure_cfg
  load_cfg

  if docker ps -a --format '{{.Names}}' | grep -qx "${NAME}"; then
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
  fi

  docker run -d \
    --name "${NAME}" \
    --restart unless-stopped \
    -p "${PORT}:3128/tcp" \
    -e "SECRET=${SECRET}" \
    "${IMAGE}" >/dev/null

  echo "MTProxy started on tcp/${PORT}"
}

ufw_open_port() {
  if have ufw; then
    if ufw status | grep -qi "Status: active"; then
      ufw allow "${PORT}/tcp" >/dev/null || true
      ufw reload >/dev/null || true
      echo "UFW: allowed ${PORT}/tcp"
    fi
  fi
}

manager_install() {
  cat > "${ROOT_DIR}/bin/${APP}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

APP="triangels-tg-bridge"
ROOT_DIR="/opt/triangels"
CFG_DIR="${ROOT_DIR}/etc"
NAME="triangels-mtproxy"

cfg_path() { echo "${CFG_DIR}/mtproxy.env"; }
have() { command -v "$1" >/dev/null 2>&1; }
require() { have "$1" || { echo "Missing dependency: $1"; exit 1; }; }

load_cfg() {
  source "$(cfg_path)"
}

public_ip_guess() {
  ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1
}

cmd_status() {
  require docker
  docker ps --filter "name=${NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

cmd_logs() {
  require docker
  docker logs --tail 200 -f "${NAME}"
}

cmd_stop() {
  require docker
  docker stop "${NAME}" >/dev/null 2>&1 || true
  echo "Stopped."
}

cmd_link() {
  load_cfg
  local ip
  ip="$(public_ip_guess)"
  local host="${1:-$ip}"
  if [[ -z "${host}" ]]; then
    echo "Could not infer IP. Use: ${APP} link <SERVER_IP>"
    exit 1
  fi
  echo "tg://proxy?server=${host}&port=${PORT}&secret=${SECRET}"
}

cmd_qr() {
  require qrencode
  local link
  link="$("$0" link "${1:-}")"
  echo "$link" | qrencode -t ansiutf8
}

cmd_help() {
  cat <<H
${APP} — TriAngels Telegram Bridge (MTProxy manager)

Commands:
  status
  logs
  stop
  link [IP]
  qr [IP]
H
}

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    status) cmd_status ;;
    logs) cmd_logs ;;
    stop) cmd_stop ;;
    link) cmd_link "$@" ;;
    qr) cmd_qr "$@" ;;
    help|--help|-h) cmd_help ;;
    *) echo "Unknown: $cmd"; cmd_help; exit 1 ;;
  esac
}
main "$@"
EOF

  chmod 0755 "${ROOT_DIR}/bin/${APP}"
  ln -sf "${ROOT_DIR}/bin/${APP}" "/usr/local/bin/${APP}"
  echo "Installed command: ${APP}"
}

main() {
  need_root
  require openssl
  ensure_docker

  ensure_dirs
  ensure_cfg
  load_cfg

  manager_install
  docker_start
  ufw_open_port

  echo
  echo "Installation complete."
  echo
  echo "Next commands:"
  echo "  ${APP} status"
  echo "  ${APP} link <SERVER_IP>"
  echo "  ${APP} qr <SERVER_IP>   (after: apt install -y qrencode)"
}

main "$@"
