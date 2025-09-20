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
  trap 'rm -rf "$tmpdir"' EXIT

  echo "[monitor-bootstrap] downloading ${url}" >&2
  curl -fsSL "$url" -o "$tmpdir/monitor.tar.gz"

  tar -xzf "$tmpdir/monitor.tar.gz" -C "$tmpdir"
  local extracted
  extracted=$(find "$tmpdir" -maxdepth 1 -type d -name 'monitor-*' -print -quit)
  if [[ -z "$extracted" ]]; then
    echo "[monitor-bootstrap] failed to locate extracted package" >&2
    exit 1
  fi

  echo "[monitor-bootstrap] running install.sh" >&2
  bash "$extracted/install.sh"
}

main "$@"
