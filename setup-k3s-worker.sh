#!/usr/bin/env bash
#
# Prepare a Debian/Ubuntu VM as a worker in an existing K3s cluster.
# Supply K3S_TOKEN through the environment or the hidden interactive prompt.
#
set -Eeuo pipefail
umask 077

K3S_URL="${K3S_URL:-}"
JOIN_TOKEN="${K3S_TOKEN:-}"
unset K3S_TOKEN
TEMP_FILES=()

usage() {
  cat <<'EOF'
Usage:
  ./setup-k3s-worker.sh --server https://SERVER:6443

Options:
  --server URL     Existing K3s server URL (or set K3S_URL)
  -h, --help       Show help

The join token is requested without echoing it, unless K3S_TOKEN is set.
Run on a new Debian/Ubuntu VM; this script never installs a K3s server or Flux.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

root() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

cleanup() {
  local file
  for file in "${TEMP_FILES[@]}"; do
    rm -f "$file"
  done
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)
      [[ -n "${2:-}" && "$2" != -* ]] || die "--server requires a URL"
      K3S_URL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1. Run with --help."
      ;;
  esac
done

[[ "$K3S_URL" =~ ^https://[^/[:space:]]+/?$ ]] ||
  die "--server must be an HTTPS server URL, e.g. https://SERVER:6443"

[[ -r /etc/os-release ]] || die "/etc/os-release is unavailable"
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "This script supports Ubuntu and Debian only" ;;
esac
case "$(uname -m)" in
  x86_64|amd64|aarch64|arm64) ;;
  *) die "Unsupported architecture" ;;
esac

if [[ "$EUID" -ne 0 ]]; then
  sudo -v
fi

# Never replace an existing server or reuse its configuration as an agent.
if command -v k3s >/dev/null 2>&1 ||
  root test -e /etc/systemd/system/k3s.service ||
  root test -e /etc/rancher/k3s/config.yaml ||
  root test -d /etc/rancher/k3s/config.yaml.d; then
  die "Existing K3s installation/configuration found; use a new VM"
fi

if [[ -z "$JOIN_TOKEN" ]]; then
  [[ -r /dev/tty ]] || die "No terminal is available. Set K3S_TOKEN."
  read -rsp "K3s join token: " JOIN_TOKEN </dev/tty
  printf '\n' >/dev/tty
fi
[[ -n "$JOIN_TOKEN" ]] || die "K3s join token cannot be empty"

printf 'Installing operating-system prerequisites\n'
root apt-get update
root env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl

printf 'Disabling swap\n'
root swapoff -a
if grep -Eq '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab; then
  root sed -i.bak \
    -E '/^[^#].*[[:space:]]swap[[:space:]]/s/^/# disabled-for-k3s: /' \
    /etc/fstab
fi

TOKEN_FILE="$(mktemp)"
TEMP_FILES+=("$TOKEN_FILE")
printf '%s' "$JOIN_TOKEN" >"$TOKEN_FILE"
unset JOIN_TOKEN
root install -d -o root -g root -m 0755 /etc/rancher/k3s
root install -o root -g root -m 0600 \
  "$TOKEN_FILE" /etc/rancher/k3s/worker-token
rm -f "$TOKEN_FILE"

INSTALLER="$(mktemp)"
TEMP_FILES+=("$INSTALLER")
curl -fsSL https://get.k3s.io -o "$INSTALLER"

printf 'Installing K3s agent (worker only)\n'
root env \
  INSTALL_K3S_EXEC=agent \
  K3S_URL="$K3S_URL" \
  K3S_TOKEN_FILE=/etc/rancher/k3s/worker-token \
  sh "$INSTALLER"

root systemctl is-active --quiet k3s-agent ||
  die "K3s agent is not active; inspect journalctl -u k3s-agent"

printf 'Worker agent is active. Verify the node is Ready from the server with sudo k3s kubectl get nodes.\n'
