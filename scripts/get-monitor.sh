#!/usr/bin/env bash
set -euo pipefail

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[monitor-bootstrap] please run with sudo or as root" >&2
    exit 1
  fi
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[monitor-bootstrap] missing required command: $cmd" >&2
    exit 1
  fi
}

fetch_latest_version() {
  local api_response
  api_response=$(curl -fsSL "https://api.github.com/repos/wfunc/monitor/releases/latest")
  if [[ -z "$api_response" ]]; then
    echo "[monitor-bootstrap] failed to fetch latest release metadata" >&2
    exit 1
  fi
  local version
  version=$(printf '%s' "$api_response" | grep -m1 '"tag_name"' | cut -d '"' -f4)
  version="${version#v}"
  if [[ -z "$version" ]]; then
    echo "[monitor-bootstrap] could not parse release version" >&2
    exit 1
  fi
  echo "$version"
}

detect_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)
      echo "amd64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    *)
      echo "[monitor-bootstrap] unsupported architecture: $arch" >&2
      exit 1
      ;;
  esac
}

configure_webhook() {
  local env_file="/etc/default/monitor"
  if [[ ! -f "$env_file" ]]; then
    echo "[monitor-bootstrap] warning: $env_file not found; skipping webhook configuration" >&2
    return
  fi

  echo ""
  echo "Webhook 配置 (留空可跳过)："
  local current
  current=$(grep -E '^MONITOR_WEBHOOK_URL=' "$env_file" | cut -d'=' -f2-)
  if [[ -n "$current" ]]; then
    echo "当前 MONITOR_WEBHOOK_URL: ${current}"
  fi
  printf "请输入新的 MONITOR_WEBHOOK_URL (或直接回车跳过): "
  read -r webhook || webhook=""
  if [[ -z "$webhook" ]]; then
    echo "[monitor-bootstrap] 保持现有 MONITOR_WEBHOOK_URL"
    return
  fi

  if grep -qE '^MONITOR_WEBHOOK_URL=' "$env_file"; then
    sed -i "s|^MONITOR_WEBHOOK_URL=.*|MONITOR_WEBHOOK_URL=${webhook}|" "$env_file"
  else
    printf '\nMONITOR_WEBHOOK_URL=%s\n' "$webhook" >> "$env_file"
  fi
  echo "[monitor-bootstrap] 已更新 MONITOR_WEBHOOK_URL"
}

maybe_start_service() {
  echo ""
  read -r -p "是否现在启动/重启 monitor.service? [Y/n]: " answer
  answer=${answer:-Y}
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    systemctl enable monitor.service >/dev/null 2>&1 || true
    systemctl restart monitor.service
    systemctl status monitor.service --no-pager
  else
    echo "[monitor-bootstrap] 已跳过服务启动，可稍后手动执行: sudo systemctl restart monitor.service"
  fi
}

main() {
  require_root
  require_command curl
  require_command tar

  local version
  version="${MONITOR_VERSION:-${1:-}}"
  version="${version#v}"
  if [[ -z "$version" ]]; then
    version=$(fetch_latest_version)
  fi

  local arch
  arch=$(detect_arch)

  local url="https://github.com/wfunc/monitor/releases/download/v${version}/monitor-${version}-linux-${arch}.tar.gz"
  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir:-}"' EXIT

  echo "[monitor-bootstrap] downloading ${url}" >&2
  curl -fsSL "$url" -o "$tmpdir/monitor.tar.gz"

  tar -xzf "$tmpdir/monitor.tar.gz" -C "$tmpdir"
  local package_dir
  package_dir=$(find "$tmpdir" -maxdepth 1 -type d -name 'monitor-*' -print -quit)
  if [[ -z "$package_dir" ]]; then
    package_dir="$tmpdir"
  fi

  local install_script="$tmpdir/install.sh"
  echo "[monitor-bootstrap] downloading latest install script" >&2
  curl -fsSL "https://raw.githubusercontent.com/wfunc/monitor/main/install.sh" -o "$install_script"
  chmod +x "$install_script"

  echo "[monitor-bootstrap] running install.sh" >&2
  USE_LOCAL_PACKAGE=1 LOCAL_PACKAGE_DIR="$package_dir" ENABLE_SERVICE=0 bash "$install_script"

  configure_webhook
  maybe_start_service
}

main "$@"
