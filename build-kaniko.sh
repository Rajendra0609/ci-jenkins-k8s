
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# -------------------------------
# build-kaniko.sh
# Run Kaniko in a Docker container to build & push an image
# -------------------------------

SCRIPT_NAME="$(basename "$0")"

log()  { printf '%s %s\n' "[INFO ]" "$*" >&2; }
warn() { printf '%s %s\n' "[WARN ]" "$*" >&2; }
err()  { printf '%s %s\n' "[ERROR]" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [options]

Options:
  --destination IMAGE        Destination image (e.g. docker.io/user/repo:tag)
  --docker-config PATH       Path to Docker config.json for registry auth
  --context PATH             Build context directory (default: current directory)
  --dockerfile PATH          Dockerfile path relative to context (default: Dockerfile)
  --cache [true|false]       Enable Kaniko cache (default: true)
  --cache-repo REPO          Cache repo (default: derived from destination if possible)
  --snapshot-mode MODE       Kaniko snapshot mode (default: redo)
  --verbosity LEVEL          Kaniko verbosity (default: info)
  --kaniko-image IMAGE       Kaniko executor image (default: gcr.io/kaniko-project/executor:latest)
  -h, --help                 Show this help

Environment variables (overrides defaults; CLI overrides env):
  DESTINATION, DOCKER_CONFIG, CONTEXT_DIR, DOCKERFILE, CACHE, CACHE_REPO,
  SNAPSHOT_MODE, VERBOSITY, KANIKO_IMAGE

Examples:
  # Minimal (uses defaults + current directory):
  DESTINATION="docker.io/daggu1997/jenkins-docker-k8s:v1.0.0" \\
  DOCKER_CONFIG="/root/.docker/config.json" \\
  $SCRIPT_NAME

  # With explicit cache repo and context:
  $SCRIPT_NAME --destination docker.io/daggu1997/jenkins-docker-k8s:v1.0.0 \\
               --docker-config /root/.docker/config.json \\
               --cache-repo docker.io/daggu1997/cache \\
               --context .

EOF
}

# -------------------------------
# Defaults (can be overridden)
# -------------------------------
DESTINATION="${DESTINATION:-}"
DOCKER_CONFIG="${DOCKER_CONFIG:-/root/.docker/config.json}"
CONTEXT_DIR="${CONTEXT_DIR:-$(pwd)}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"
CACHE="${CACHE:-true}"
CACHE_REPO="${CACHE_REPO:-}"
SNAPSHOT_MODE="${SNAPSHOT_MODE:-redo}"
VERBOSITY="${VERBOSITY:-info}"
KANIKO_IMAGE="${KANIKO_IMAGE:-gcr.io/kaniko-project/executor:latest}"

# -------------------------------
# Parse CLI args
# -------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --destination)   DESTINATION="${2:-}"; shift 2 ;;
    --docker-config) DOCKER_CONFIG="${2:-}"; shift 2 ;;
    --context)       CONTEXT_DIR="${2:-}"; shift 2 ;;
    --dockerfile)    DOCKERFILE="${2:-}"; shift 2 ;;
    --cache)         CACHE="${2:-}"; shift 2 ;;
    --cache-repo)    CACHE_REPO="${2:-}"; shift 2 ;;
    --snapshot-mode) SNAPSHOT_MODE="${2:-}"; shift 2 ;;
    --verbosity)     VERBOSITY="${2:-}"; shift 2 ;;
    --kaniko-image)  KANIKO_IMAGE="${2:-}"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)
      die "Unknown argument: $1. Use --help."
      ;;
  esac
done

# -------------------------------
# Validation
# -------------------------------
command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH."

[[ -n "$DESTINATION" ]] || die "DESTINATION is required. Provide --destination or set DESTINATION env var."

[[ -d "$CONTEXT_DIR" ]] || die "Context directory does not exist: $CONTEXT_DIR"

# Resolve absolute path for context
CONTEXT_DIR="$(cd "$CONTEXT_DIR" && pwd)"

[[ -f "$CONTEXT_DIR/$DOCKERFILE" ]] || die "Dockerfile not found: $CONTEXT_DIR/$DOCKERFILE"

[[ -f "$DOCKER_CONFIG" ]] || die "Docker config.json not found: $DOCKER_CONFIG"
[[ -r "$DOCKER_CONFIG" ]] || die "Docker config.json is not readable: $DOCKER_CONFIG"

case "$CACHE" in
  true|false) ;;
  *) die "--cache must be true or false (got: $CACHE)" ;;
esac

# Derive default cache repo if not provided
# If destination is like docker.io/user/repo:tag -> cache repo docker.io/user/cache
if [[ -z "$CACHE_REPO" ]]; then
  # Extract registry/user (first 2 path segments) from destination if possible
  # e.g. docker.io/daggu1997/jenkins-docker-k8s:v1 -> docker.io/daggu1997
  base="${DESTINATION%:*}"          # remove tag
  prefix="$(awk -F/ '{print $1"/"$2}' <<<"$base" || true)"
  if [[ -n "$prefix" && "$prefix" == */* ]]; then
    CACHE_REPO="${prefix}/cache"
    warn "CACHE_REPO not provided. Using derived cache repo: $CACHE_REPO"
  else
    warn "CACHE_REPO not provided and could not be derived. Cache may be less effective."
  fi
fi

# -------------------------------
# Run Kaniko via Docker
# -------------------------------
log "Kaniko image     : $KANIKO_IMAGE"
log "Context          : $CONTEXT_DIR"
log "Dockerfile       : $DOCKERFILE"
log "Destination      : $DESTINATION"
log "Docker config    : $DOCKER_CONFIG"
log "Cache enabled    : $CACHE"
log "Cache repo       : ${CACHE_REPO:-<none>}"
log "Snapshot mode    : $SNAPSHOT_MODE"
log "Verbosity        : $VERBOSITY"

# Use read-only mount for docker config for safety
# Always mount /workspace to context
docker run --rm \
  -v "$CONTEXT_DIR":/workspace \
  -v "$DOCKER_CONFIG":/kaniko/.docker/config.json:ro \
  "$KANIKO_IMAGE" \
  --dockerfile="$DOCKERFILE" \
  --context=/workspace \
  --destination="$DESTINATION" \
  --cache="$CACHE" \
  ${CACHE_REPO:+--cache-repo="$CACHE_REPO"} \
  --snapshotMode="$SNAPSHOT_MODE" \
  --verbosity="$VERBOSITY"

log "Build completed successfully."

