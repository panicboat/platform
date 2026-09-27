set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*" >&2; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }

require_env() {
  if [ "${ENV:-}" != "production" ]; then
    error "ENV must be 'production' (got: '${ENV:-<unset>}')"
    exit 1
  fi
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      error "required command not found: $cmd"
      exit 1
    fi
  done
}

confirm() {
  local prompt="$1"
  local reply
  read -r -p "$prompt [y/N] " reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    info "Cancelled."
    exit 0
  fi
}

run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf "${YELLOW}[DRY-RUN]${NC} %s\n" "$*"
  else
    "$@"
  fi
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export REPO_ROOT

resolve_aws_region() {
  # BSD sed (= macOS default) does not understand \s; use [[:space:]] for portability.
  local env_file="${REPO_ROOT}/aws/eks/${ENV}/env.hcl"
  if [ -f "$env_file" ]; then
    grep -E '^[[:space:]]*aws_region[[:space:]]*=' "$env_file" | head -1 | \
      sed -E 's/^[[:space:]]*aws_region[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/'
  else
    echo "ap-northeast-1"
  fi
}

# Tracks UNIX epoch expiration to trigger re-authentication when less than 5 minutes remain.
CREDS_EXPIRE_FILE="/tmp/eks-lifecycle-creds-expire-$$"
export CREDS_EXPIRE_FILE

creds_expiring_soon() {
  if [ ! -f "$CREDS_EXPIRE_FILE" ]; then
    return 0
  fi
  local expire_at now remaining
  expire_at=$(cat "$CREDS_EXPIRE_FILE")
  now=$(date +%s)
  remaining=$((expire_at - now))
  if [ "$remaining" -lt 300 ]; then
    return 0
  fi
  return 1
}
