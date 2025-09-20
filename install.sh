#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/wfunc/monitor.git}"
REPO_REF="${REPO_REF:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/wfunc-monitor}"
BIN_PATH="${BIN_PATH:-/usr/local/bin/monitor}"
SERVICE_NAME="${SERVICE_NAME:-monitor.service}"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
ENV_FILE="${ENV_FILE:-/etc/default/monitor}"
MONITOR_USER="${MONITOR_USER:-monitor}"
ENABLE_SERVICE="${ENABLE_SERVICE:-1}"

log() {
  echo "[monitor-install] $*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "this installer must run as root; try: sudo bash install.sh"
    exit 1
  fi
}

assert_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "missing required command: $cmd"
    exit 1
  fi
}

install_dependencies() {
  if command -v apt-get >/dev/null 2>&1; then
    log "installing dependencies via apt-get"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y git golang-go ca-certificates
  else
    log "unsupported package manager; please install git and Go manually"
    exit 1
  fi
}

ensure_dependencies() {
  local missing=()
  for cmd in git go systemctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if ((${#missing[@]})); then
    install_dependencies
  fi
}

setup_monitor_user() {
  if ! getent group "${MONITOR_USER}" >/dev/null 2>&1; then
    log "creating group ${MONITOR_USER}"
    groupadd --system "${MONITOR_USER}"
  fi
  if ! id -u "${MONITOR_USER}" >/dev/null 2>&1; then
    log "creating user ${MONITOR_USER}"
    useradd --system --gid "${MONITOR_USER}" --home-dir "${INSTALL_DIR}" --shell /usr/sbin/nologin "${MONITOR_USER}"
  fi
}

sync_source() {
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    log "updating existing repository in ${INSTALL_DIR}"
    git -C "${INSTALL_DIR}" fetch --tags --force origin
    git -C "${INSTALL_DIR}" checkout "${REPO_REF}"
    git -C "${INSTALL_DIR}" reset --hard "origin/${REPO_REF}"
  else
    log "cloning ${REPO_URL} into ${INSTALL_DIR}"
    rm -rf "${INSTALL_DIR}"
    git clone "${REPO_URL}" "${INSTALL_DIR}"
    git -C "${INSTALL_DIR}" checkout "${REPO_REF}"
  fi
  chown -R "${MONITOR_USER}:${MONITOR_USER}" "${INSTALL_DIR}"
}

build_binary() {
  log "building monitor binary"
  install -d "$(dirname "${BIN_PATH}")"
  pushd "${INSTALL_DIR}" >/dev/null
  go build -o "${BIN_PATH}"
  popd >/dev/null
  chmod 0755 "${BIN_PATH}"
  chown "root:root" "${BIN_PATH}"
}

install_unit_files() {
  log "installing systemd unit to ${SERVICE_PATH}"
  install -D -m 0644 "${INSTALL_DIR}/systemd/monitor.service" "${SERVICE_PATH}"
  if [[ ! -f "${ENV_FILE}" ]]; then
    log "installing default environment file to ${ENV_FILE}"
    install -D -m 0644 "${INSTALL_DIR}/systemd/monitor.env.example" "${ENV_FILE}"
  else
    log "preserving existing ${ENV_FILE}"
  fi
  systemctl daemon-reload
}

enable_service() {
  if [[ "${ENABLE_SERVICE}" == "1" ]]; then
    log "enabling and starting ${SERVICE_NAME}"
    systemctl enable --now "${SERVICE_NAME}"
  else
    log "skipping service enable/start (ENABLE_SERVICE=${ENABLE_SERVICE})"
  fi
}

main() {
  require_root
  ensure_dependencies
  assert_command git
  assert_command go
  assert_command systemctl
  setup_monitor_user
  if [[ "${INSTALL_DIR}" == "/" ]]; then
    log "INSTALL_DIR cannot be /"
    exit 1
  fi
  install -d -o "${MONITOR_USER}" -g "${MONITOR_USER}" -m 0755 "${INSTALL_DIR}"
  sync_source
  build_binary
  install_unit_files
  enable_service
  log "installation complete"
  log "Edit ${ENV_FILE} and run: systemctl restart ${SERVICE_NAME} to apply changes"
  log "Ensure MONITOR_WEBHOOK_URL is set; alerts do not send without it"
}

main "$@"
