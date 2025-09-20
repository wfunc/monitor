#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DIST_DIR="${ROOT_DIR}/dist"
VERSION_FILE="${ROOT_DIR}/VERSION"
VERSION="${1:-}"

if [[ -z "${VERSION}" ]]; then
  if [[ -f "${VERSION_FILE}" ]]; then
    VERSION=$(<"${VERSION_FILE}")
  else
    echo "Usage: $0 <version>" >&2
    exit 1
  fi
fi

VERSION=$(echo "${VERSION}" | tr -d '[:space:]')
if [[ -z "${VERSION}" ]]; then
  echo "Version value is empty" >&2
  exit 1
fi

rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

declare -a TARGETS=(
  "linux amd64"
  "linux arm64"
)

for target in "${TARGETS[@]}"; do
  IFS=' ' read -r GOOS GOARCH <<<"${target}"
  OUTPUT_DIR="${DIST_DIR}/monitor-${VERSION}-${GOOS}-${GOARCH}"
  ARCHIVE="${OUTPUT_DIR}.tar.gz"

  mkdir -p "${OUTPUT_DIR}"

  echo "Building ${GOOS}/${GOARCH}"
  GOOS="${GOOS}" GOARCH="${GOARCH}" CGO_ENABLED=0 \
    go build -ldflags "-s -w" -o "${OUTPUT_DIR}/monitor" "${ROOT_DIR}"

  mkdir -p "${OUTPUT_DIR}/systemd"
  cp "${ROOT_DIR}/systemd/monitor.service" "${OUTPUT_DIR}/systemd/monitor.service"
  cp "${ROOT_DIR}/systemd/monitor.env.example" "${OUTPUT_DIR}/systemd/monitor.env.example"
  cp "${ROOT_DIR}/README.md" "${OUTPUT_DIR}/README.md"
  cp "${ROOT_DIR}/install.sh" "${OUTPUT_DIR}/install.sh"

  tar -C "${OUTPUT_DIR}" -czf "${ARCHIVE}" .
  rm -rf "${OUTPUT_DIR}"
  echo "Created ${ARCHIVE}"
done

CHECKSUM_FILE="${DIST_DIR}/checksums.txt"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "${DIST_DIR}"/*.tar.gz > "${CHECKSUM_FILE}"
else
  shasum -a 256 "${DIST_DIR}"/*.tar.gz > "${CHECKSUM_FILE}"
fi

echo "Wrote checksums to ${CHECKSUM_FILE}"
