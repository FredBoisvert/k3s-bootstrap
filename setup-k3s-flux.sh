#!/usr/bin/env bash
#
# Prepare a Debian/Ubuntu VM as a single-node K3s cluster managed by Flux.
#
# Secrets are requested interactively unless supplied through:
#   REGISTRY_PASSWORD
#   FLUX_GIT_PAT
#
# WARNING: Environment variables may be observable by privileged processes.
# Interactive prompting is preferable.
#
set -Eeuo pipefail
umask 077

VERBOSE=false
CONFIGURE_UFW=false
EXPOSE_API=false

GIT_URL="${GIT_URL:-}"
GIT_BRANCH="${GIT_BRANCH:-main}"
GIT_PATH="${GIT_PATH:-./apps}"
GIT_USERNAME="${GIT_USERNAME:-flux}"

FLUX_SOURCE_NAME="${FLUX_SOURCE_NAME:-flux-system}"
FLUX_KUSTOMIZATION_NAME="${FLUX_KUSTOMIZATION_NAME:-apps}"

REGISTRY_HOST="${REGISTRY_HOST:-}"
REGISTRY_USERNAME="${REGISTRY_USERNAME:-}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-}"
TEST_IMAGE="${TEST_IMAGE:-}"

APP_NAMESPACE="${APP_NAMESPACE:-}"
KUBE_USER="${KUBE_USER:-}"

FLUX_GIT_PAT="${FLUX_GIT_PAT:-}"

TEMP_FILES=()

usage() {
  cat <<'EOF'
Usage:
  ./prepare-k3s-flux.sh [options]

Required:
  --git-url URL                 Azure DevOps Git repository URL
  --registry HOST              Registry hostname, e.g. myregistry.azurecr.io
  --registry-user USER         Registry username; for ACR use the service
                               principal application/client ID

Strongly recommended:
  --app-namespace NAMESPACE     Namespace containing the HelmRelease object.
                               It is created before Flux applies ./apps.

Optional:
  --git-branch BRANCH           Git branch (default: main)
  --git-path PATH               Path Flux applies (default: ./apps)
  --git-user USER               HTTPS username used with PAT (default: flux)
  --source-name NAME            Flux GitRepository name (default: flux-system)
  --kustomization-name NAME     Flux Kustomization name (default: apps)
  --test-image IMAGE            Test pulling this exact image with K3s CRI
  --kube-user USER              Local Linux user receiving ~/.kube/config
  --configure-ufw               Allow TCP 80 and 443 if UFW is active
  --expose-api                  Also allow TCP 6443 when configuring UFW
  -v, --verbose                 Print operational details and commands
  -h, --help                    Show help

Secret input:
  The script interactively requests:
    - Registry password/client secret
    - Azure DevOps PAT

  They can instead be supplied through:
    REGISTRY_PASSWORD
    FLUX_GIT_PAT

Examples:
  ./prepare-k3s-flux.sh \
    --git-url "https://dev.azure.com/contoso/platform/_git/edge-gitops" \
    --git-branch main \
    --git-path ./apps \
    --app-namespace myapp \
    --registry contosoedge.azurecr.io \
    --registry-user 11111111-2222-3333-4444-555555555555 \
    --test-image contosoedge.azurecr.io/myapp:12345 \
    --verbose

  REGISTRY_PASSWORD='...' FLUX_GIT_PAT='...' \
  ./prepare-k3s-flux.sh \
    --git-url "https://dev.azure.com/contoso/platform/_git/edge-gitops" \
    --app-namespace myapp \
    --registry contosoedge.azurecr.io \
    --registry-user 11111111-2222-3333-4444-555555555555
EOF
}

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

verbose() {
  if [[ "$VERBOSE" == true ]]; then
    printf '[VERBOSE] %s\n' "$*"
  fi
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local file
  for file in "${TEMP_FILES[@]:-}"; do
    [[ -n "$file" ]] && rm -f "$file"
  done
}
trap cleanup EXIT

run() {
  if [[ "$VERBOSE" == true ]]; then
    printf '[COMMAND]'
    printf ' %q' "$@"
    printf '\n'
  fi
  "$@"
}

root() {
  if [[ "$EUID" -eq 0 ]]; then
    run "$@"
  else
    run sudo "$@"
  fi
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || die "$option requires a value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --git-url)
      require_value "$1" "${2:-}"
      GIT_URL="$2"
      shift 2
      ;;
    --git-branch)
      require_value "$1" "${2:-}"
      GIT_BRANCH="$2"
      shift 2
      ;;
    --git-path)
      require_value "$1" "${2:-}"
      GIT_PATH="$2"
      shift 2
      ;;
    --git-user)
      require_value "$1" "${2:-}"
      GIT_USERNAME="$2"
      shift 2
      ;;
    --source-name)
      require_value "$1" "${2:-}"
      FLUX_SOURCE_NAME="$2"
      shift 2
      ;;
    --kustomization-name)
      require_value "$1" "${2:-}"
      FLUX_KUSTOMIZATION_NAME="$2"
      shift 2
      ;;
    --registry)
      require_value "$1" "${2:-}"
      REGISTRY_HOST="$2"
      shift 2
      ;;
    --registry-user)
      require_value "$1" "${2:-}"
      REGISTRY_USERNAME="$2"
      shift 2
      ;;
    --test-image)
      require_value "$1" "${2:-}"
      TEST_IMAGE="$2"
      shift 2
      ;;
    --app-namespace)
      require_value "$1" "${2:-}"
      APP_NAMESPACE="$2"
      shift 2
      ;;
    --kube-user)
      require_value "$1" "${2:-}"
      KUBE_USER="$2"
      shift 2
      ;;
    --configure-ufw)
      CONFIGURE_UFW=true
      shift
      ;;
    --expose-api)
      EXPOSE_API=true
      shift
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
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

[[ -n "$GIT_URL" ]]          || die "--git-url is required"
[[ -n "$REGISTRY_HOST" ]]     || die "--registry is required"
[[ -n "$REGISTRY_USERNAME" ]] || die "--registry-user is required"

# Reject common registry formatting errors.
[[ "$REGISTRY_HOST" != http://* ]]  || die "--registry must not include http://"
[[ "$REGISTRY_HOST" != https://* ]] || die "--registry must not include https://"
[[ "$REGISTRY_HOST" != */* ]]       || die "--registry must contain only the hostname"

if [[ -z "$KUBE_USER" ]]; then
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    KUBE_USER="$SUDO_USER"
  else
    KUBE_USER="$(id -un)"
  fi
fi

if ! getent passwd "$KUBE_USER" >/dev/null; then
  die "Local Linux user does not exist: $KUBE_USER"
fi

KUBE_HOME="$(getent passwd "$KUBE_USER" | cut -d: -f6)"
[[ -n "$KUBE_HOME" ]] || die "Could not determine home directory for $KUBE_USER"

if [[ -z "$REGISTRY_PASSWORD" ]]; then
  [[ -r /dev/tty ]] || die \
    "No terminal is available. Set REGISTRY_PASSWORD in the environment."

  read -rsp "Registry password/client secret: " REGISTRY_PASSWORD </dev/tty
  printf '\n' >/dev/tty
fi

if [[ -z "$FLUX_GIT_PAT" ]]; then
  [[ -r /dev/tty ]] || die \
    "No terminal is available. Set FLUX_GIT_PAT in the environment."

  read -rsp "Azure DevOps read-only PAT: " FLUX_GIT_PAT </dev/tty
  printf '\n' >/dev/tty
fi

[[ -n "$REGISTRY_PASSWORD" ]] || die "Registry password cannot be empty"
[[ -n "$FLUX_GIT_PAT" ]]      || die "Azure DevOps PAT cannot be empty"

if [[ "$EUID" -ne 0 ]]; then
  log "Validating sudo access"
  sudo -v
fi

log "Provisioning summary"
cat <<EOF
Kubeconfig user:       $KUBE_USER
Kubeconfig location:   $KUBE_HOME/.kube/config
Registry:              $REGISTRY_HOST
Git repository:        $GIT_URL
Git branch:            $GIT_BRANCH
Git reconciliation:    $GIT_PATH
Flux source:           $FLUX_SOURCE_NAME
Flux Kustomization:    $FLUX_KUSTOMIZATION_NAME
Application namespace: ${APP_NAMESPACE:-not specified}
Test image:             ${TEST_IMAGE:-not specified}
EOF

log "Checking operating system"

[[ -r /etc/os-release ]] || die "/etc/os-release is unavailable"
# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
  ubuntu|debian)
    verbose "Detected ${PRETTY_NAME:-$ID}"
    ;;
  *)
    die "This script supports Ubuntu and Debian. Detected: ${PRETTY_NAME:-unknown}"
    ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64|aarch64|arm64)
    verbose "Supported architecture detected: $ARCH"
    ;;
  *)
    die "Unsupported architecture: $ARCH"
    ;;
esac

log "Installing operating-system prerequisites"

root apt-get update
root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates \
  curl \
  git \
  jq \
  openssl \
  tar \
  gzip

log "Disabling swap"

root swapoff -a

if grep -Eq '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab; then
  verbose "Commenting active swap entries in /etc/fstab"
  root sed -i.bak \
    -E '/^[^#].*[[:space:]]swap[[:space:]]/s/^/# disabled-for-k3s: /' \
    /etc/fstab
else
  verbose "No active swap entry was found in /etc/fstab"
fi

log "Preparing K3s global registry configuration"

REGISTRY_CONFIG="$(mktemp)"
TEMP_FILES+=("$REGISTRY_CONFIG")

# JSON is valid YAML. jq provides correct escaping for special characters in
# service-principal secrets.
jq -n \
  --arg registry "$REGISTRY_HOST" \
  --arg username "$REGISTRY_USERNAME" \
  --arg password "$REGISTRY_PASSWORD" \
  '{
    configs: {
      ($registry): {
        auth: {
          username: $username,
          password: $password
        }
      }
    }
  }' >"$REGISTRY_CONFIG"

root mkdir -p /etc/rancher/k3s
root install \
  -o root \
  -g root \
  -m 0600 \
  "$REGISTRY_CONFIG" \
  /etc/rancher/k3s/registries.yaml

verbose "Installed /etc/rancher/k3s/registries.yaml with mode 0600"
rm -f "$REGISTRY_CONFIG"

log "Installing or validating K3s"

if command -v k3s >/dev/null 2>&1; then
  verbose "K3s is already installed; preserving the existing installation"
  root systemctl enable k3s
  root systemctl restart k3s
else
  K3S_INSTALLER="$(mktemp)"
  TEMP_FILES+=("$K3S_INSTALLER")

  run curl -fsSL https://get.k3s.io -o "$K3S_INSTALLER"

  # A normal single-server installation uses SQLite and includes:
  # containerd, Traefik, Flannel, ServiceLB and local-path storage.
  root env INSTALL_K3S_EXEC="server" sh "$K3S_INSTALLER"

  rm -f "$K3S_INSTALLER"
fi

log "Waiting for the K3s service and Kubernetes node"

root systemctl is-active --quiet k3s || {
  root systemctl status k3s --no-pager || true
  root journalctl -u k3s -n 200 --no-pager || true
  die "K3s did not start successfully"
}

K3S_READY=false
for attempt in $(seq 1 60); do
  if root k3s kubectl get node >/dev/null 2>&1; then
    NODE_READY="$(
      root k3s kubectl get nodes \
        -o jsonpath='{range .items[*]}{range .status.conditions