#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║              RAJA DEVOPS DASHBOARD — ADVANCED                ║
# ║  Modular · Parallel · AWS-Aware · Threshold Alerts           ║
# ╚══════════════════════════════════════════════════════════════╝
#
# Usage: ./dashboard.sh [OPTIONS]
#   -s <sections>   Comma-separated list of sections to run
#                   Sections: git,cicd,k8s,aws,github,docker,jfrog,
#                             gerrit,resources,tools,network,ssl
#   -o <file>       Write output to a log file as well
#   -q              Quiet: suppress warnings, show only pass/fail
#   -x              Exit with non-zero code if any check fails
#   -h              Show help

set -euo pipefail

# ─────────────────────────────────────────────────────────────────
# COLORS & SYMBOLS
# ─────────────────────────────────────────────────────────────────
GREEN="\e[32m"; RED="\e[31m"; YELLOW="\e[33m"; BLUE="\e[34m"
CYAN="\e[36m";  MAGENTA="\e[35m"; RESET="\e[0m"; BOLD="\e[1m"
DIM="\e[2m"; UNDERLINE="\e[4m"

# ─────────────────────────────────────────────────────────────────
# GLOBALS
# ─────────────────────────────────────────────────────────────────
start_time=$(date +%s)
PASSED=0; FAILED=0; WARN=0
LOG_FILE=""
QUIET=false
EXIT_ON_FAIL=false
TMPDIR_DASHBOARD=$(mktemp -d)
trap 'rm -rf "$TMPDIR_DASHBOARD"' EXIT

# Default sections (all)
ALL_SECTIONS="git,cicd,k8s,aws,github,docker,jfrog,gerrit,resources,tools,network,ssl"
RUN_SECTIONS="$ALL_SECTIONS"

# ─────────────────────────────────────────────────────────────────
# CONFIG FILE  — override defaults in ~/.dashboard_config
# ─────────────────────────────────────────────────────────────────
CONFIG_FILE="${HOME}/.dashboard_config"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# Config variables (can be set in ~/.dashboard_config):
DISK_WARN_THRESHOLD="${DISK_WARN_THRESHOLD:-70}"     # % — yellow
DISK_CRIT_THRESHOLD="${DISK_CRIT_THRESHOLD:-85}"     # % — red
MEM_WARN_THRESHOLD="${MEM_WARN_THRESHOLD:-75}"       # %
MEM_CRIT_THRESHOLD="${MEM_CRIT_THRESHOLD:-90}"       # %
LOAD_WARN_THRESHOLD="${LOAD_WARN_THRESHOLD:-2.0}"    # per core
SSL_WARN_DAYS="${SSL_WARN_DAYS:-30}"                 # days before expiry
SSL_DOMAINS="${SSL_DOMAINS:-}"                       # space-separated domains
NETWORK_HOSTS="${NETWORK_HOSTS:-8.8.8.8 1.1.1.1}"   # ping targets
PORT_CHECKS="${PORT_CHECKS:-}"                       # "host:port host:port ..."
ARTIFACTORY_URL="${ARTIFACTORY_URL:-}"
GERRIT_URL="${GERRIT_URL:-}"

# ─────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────
while getopts "s:o:qxh" opt; do
  case $opt in
    s) RUN_SECTIONS="$OPTARG" ;;
    o) LOG_FILE="$OPTARG" ;;
    q) QUIET=true ;;
    x) EXIT_ON_FAIL=true ;;
    h)
      grep '^# Usage:' "$0" -A 15 | sed 's/^# //'
      exit 0
      ;;
    *) echo "Unknown option -$OPTARG" >&2; exit 1 ;;
  esac
done

section_enabled() {
  [[ ",$RUN_SECTIONS," == *",$1,"* ]]
}

# ─────────────────────────────────────────────────────────────────
# OUTPUT HELPERS
# ─────────────────────────────────────────────────────────────────
_tee() {
  if [[ -n "$LOG_FILE" ]]; then
    tee -a "$LOG_FILE"
  else
    cat
  fi
}

print_line() {
  echo -e "${CYAN}────────────────────────────────────────────────────────────${RESET}" | _tee
}

print_double_line() {
  echo -e "${CYAN}════════════════════════════════════════════════════════════${RESET}" | _tee
}

print_section() {
  echo "" | _tee
  echo -e "${BOLD}${MAGENTA}  ◈  $1${RESET}" | _tee
  print_line
}

print_status() {
  local status=$1 message="$2" detail="${3:-}"
  local detail_str=""
  [[ -n "$detail" ]] && detail_str=" ${DIM}($detail)${RESET}"

  if   [[ "$status" -eq 0 ]]; then
    echo -e "   ${GREEN}✔${RESET}  $message${detail_str}" | _tee
    PASSED=$((PASSED+1))
  elif [[ "$status" -eq 2 ]]; then
    $QUIET || echo -e "   ${YELLOW}⚠${RESET}  $message${detail_str}" | _tee
    WARN=$((WARN+1))
  else
    echo -e "   ${RED}✖${RESET}  ${RED}$message${RESET}${detail_str}" | _tee
    FAILED=$((FAILED+1))
  fi
}

kv() {
  local key="$1" value="$2" color="${3:-}"
  local colored_val
  [[ -n "$color" ]] && colored_val="${color}${value}${RESET}" || colored_val="$value"
  printf "   %-24s %s\n" "${DIM}${key}${RESET}" "$colored_val" | _tee
}

# ─────────────────────────────────────────────────────────────────
# SPINNER  (shows while background jobs run)
# ─────────────────────────────────────────────────────────────────
spinner() {
  local pid=$1 label="${2:-Working}"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r   ${CYAN}%s${RESET} %s " "${frames[$((i % 10))]}" "$label"
    sleep 0.1
    i=$((i+1))
  done
  printf "\r\033[K"   # clear line
}

# ─────────────────────────────────────────────────────────────────
# THRESHOLD HELPERS
# ─────────────────────────────────────────────────────────────────
threshold_status() {
  # Returns 0 (ok), 1 (critical), 2 (warn) based on numeric value + thresholds
  local val=$1 warn=$2 crit=$3
  if   (( $(echo "$val >= $crit" | bc -l) )); then echo 1
  elif (( $(echo "$val >= $warn" | bc -l) )); then echo 2
  else echo 0
  fi
}

# ─────────────────────────────────────────────────────────────────
# SECTION: SYSTEM INFO
# ─────────────────────────────────────────────────────────────────
section_system() {
  print_section "💻  SYSTEM"
  kv "Hostname"    "$(hostname -f 2>/dev/null || hostname)"
  kv "User"        "$(whoami)"
  kv "OS"          "$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || uname -s)"
  kv "Kernel"      "$(uname -r)"
  kv "Uptime"      "$(uptime -p 2>/dev/null || uptime | awk -F 'up ' '{print $2}' | cut -d ',' -f1)"
  kv "Timestamp"   "$(date '+%Y-%m-%d %H:%M:%S %Z')"
}

# ─────────────────────────────────────────────────────────────────
# SECTION: GIT
# ─────────────────────────────────────────────────────────────────
section_git() {
  section_enabled git || return 0
  print_section "🌿  GIT PROJECT"

  git_root=$(git rev-parse --show-toplevel 2>/dev/null) || { print_status 1 "Not a git repository"; return; }

  kv "Project"        "$(basename "$git_root")"
  kv "Branch"         "$(git -C "$git_root" rev-parse --abbrev-ref HEAD)"
  kv "Remote"         "$(git -C "$git_root" remote get-url origin 2>/dev/null || echo 'none')"
  kv "Commit SHA"     "$(git -C "$git_root" rev-parse --short HEAD)"
  kv "Author"         "$(git -C "$git_root" log -1 --pretty=format:'%an <%ae>')"
  kv "Message"        "$(git -C "$git_root" log -1 --pretty=%s)"
  kv "Date"           "$(git -C "$git_root" log -1 --pretty=format:'%ar')"

  # Uncommitted changes
  local unstaged staged untracked
  unstaged=$(git -C "$git_root" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
  staged=$(git -C "$git_root" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
  untracked=$(git -C "$git_root" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
  stash=$(git -C "$git_root" stash list 2>/dev/null | wc -l | tr -d ' ')

  [[ "$unstaged" -gt 0 ]]  && print_status 2 "Unstaged changes: $unstaged file(s)"   || print_status 0 "Working tree clean (unstaged)"
  [[ "$staged" -gt 0 ]]    && print_status 2 "Staged (uncommitted): $staged file(s)" || print_status 0 "Nothing staged"
  [[ "$untracked" -gt 0 ]] && print_status 2 "Untracked files: $untracked"
  [[ "$stash" -gt 0 ]]     && print_status 2 "Stash entries: $stash"

  # Ahead/behind remote
  if git -C "$git_root" fetch --dry-run &>/dev/null; then
    local ahead behind
    ahead=$(git -C "$git_root" rev-list "@{u}..HEAD" 2>/dev/null | wc -l | tr -d ' ')
    behind=$(git -C "$git_root" rev-list "HEAD..@{u}" 2>/dev/null | wc -l | tr -d ' ')
    [[ "$ahead"  -gt 0 ]] && print_status 2 "Ahead of remote by $ahead commit(s)"
    [[ "$behind" -gt 0 ]] && print_status 2 "Behind remote by $behind commit(s)"
    [[ "$ahead" -eq 0 && "$behind" -eq 0 ]] && print_status 0 "In sync with remote"
  fi
}

# ─────────────────────────────────────────────────────────────────
# SECTION: CI/CD ENVIRONMENT
# ─────────────────────────────────────────────────────────────────
section_cicd() {
  section_enabled cicd || return 0
  print_section "🤖  CI/CD ENVIRONMENT"

  if [[ -n "${JENKINS_HOME:-}" ]]; then
    print_status 0 "Running inside Jenkins"
    kv "Job"          "${JOB_NAME:-N/A}"
    kv "Build #"      "${BUILD_NUMBER:-N/A}"
    kv "Build URL"    "${BUILD_URL:-N/A}"
    kv "Node"         "${NODE_NAME:-N/A}"
    kv "Workspace"    "${WORKSPACE:-N/A}"
    kv "Triggered by" "${BUILD_CAUSE:-N/A}"
  elif [[ -n "${GITLAB_CI:-}" ]]; then
    print_status 0 "Running inside GitLab CI"
    kv "Pipeline ID"  "${CI_PIPELINE_ID:-N/A}"
    kv "Job"          "${CI_JOB_NAME:-N/A}"
    kv "Runner"       "${CI_RUNNER_DESCRIPTION:-N/A}"
    kv "Branch/Tag"   "${CI_COMMIT_REF_NAME:-N/A}"
    kv "Commit SHA"   "${CI_COMMIT_SHORT_SHA:-N/A}"
    kv "Project"      "${CI_PROJECT_PATH:-N/A}"
  elif [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    print_status 0 "Running inside GitHub Actions"
    kv "Workflow"     "${GITHUB_WORKFLOW:-N/A}"
    kv "Run ID"       "${GITHUB_RUN_ID:-N/A}"
    kv "Actor"        "${GITHUB_ACTOR:-N/A}"
    kv "Ref"          "${GITHUB_REF:-N/A}"
    kv "SHA"          "${GITHUB_SHA:0:8}...${GITHUB_SHA: -4}"
    kv "Runner OS"    "${RUNNER_OS:-N/A}"

    # OIDC detection
    if [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]]; then
      print_status 0 "OIDC token endpoint available (IRSA/OIDC auth enabled)"
      kv "Token URL"  "${ACTIONS_ID_TOKEN_REQUEST_URL:-N/A}"
    else
      print_status 2 "OIDC token endpoint not set (id-token: write permission needed)"
    fi
  else
    print_status 2 "Not running in recognized CI/CD environment (local mode)"
  fi
}

# ─────────────────────────────────────────────────────────────────
# SECTION: KUBERNETES
# ─────────────────────────────────────────────────────────────────
section_k8s() {
  section_enabled k8s || return 0
  print_section "☸️   KUBERNETES"

  if [[ -z "${KUBERNETES_SERVICE_HOST:-}" ]]; then
    # Not inside a pod — try kubeconfig
    if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
      print_status 2 "Not in-cluster, but kubeconfig is active"
      kv "Context"    "$(kubectl config current-context 2>/dev/null)"
      kv "Server"     "$(kubectl cluster-info 2>/dev/null | head -1 | sed 's/.*at //')"
    else
      print_status 2 "Not running in Kubernetes (no in-cluster env, no active kubeconfig)"
    fi
    return
  fi

  print_status 0 "Running inside a Kubernetes Pod"
  kv "Pod Name"       "${HOSTNAME}"
  kv "Namespace"      "$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo "${POD_NAMESPACE:-default}")"
  kv "Pod IP"         "$(hostname -i 2>/dev/null)"
  kv "Node"           "${NODE_NAME:-N/A}"
  kv "SA"             "$(cat /var/run/secrets/kubernetes.io/serviceaccount/serviceaccount.name 2>/dev/null | tr -d '\n' || echo 'N/A')"

  # IRSA detection (AWS IAM Roles for Service Accounts)
  if [[ -n "${AWS_ROLE_ARN:-}" && -n "${AWS_WEB_IDENTITY_TOKEN_FILE:-}" ]]; then
    print_status 0 "IRSA configured"
    kv "Role ARN"     "$AWS_ROLE_ARN"
    kv "Token file"   "$AWS_WEB_IDENTITY_TOKEN_FILE"

    # Check token file exists and is fresh
    if [[ -f "$AWS_WEB_IDENTITY_TOKEN_FILE" ]]; then
      local age_sec token_age_str
      age_sec=$(( $(date +%s) - $(stat -c %Y "$AWS_WEB_IDENTITY_TOKEN_FILE" 2>/dev/null || echo 0) ))
      if   [[ $age_sec -lt 300  ]]; then token_age_str="fresh (${age_sec}s old)"
      elif [[ $age_sec -lt 3600 ]]; then token_age_str="${age_sec}s old"
      else token_age_str="$(( age_sec/3600 ))h old — may need rotation"
      fi
      print_status 0 "Web identity token present" "$token_age_str"
    else
      print_status 1 "Web identity token file missing: $AWS_WEB_IDENTITY_TOKEN_FILE"
    fi
  else
    print_status 2 "IRSA not configured (AWS_ROLE_ARN / AWS_WEB_IDENTITY_TOKEN_FILE not set)"
  fi

  # Try kubectl if available
  if command -v kubectl &>/dev/null; then
    local node_count pod_count ns_count
    node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    pod_count=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ns_count=$(kubectl get namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
    kv "Nodes"        "$node_count"
    kv "Pods"         "$pod_count (all namespaces)"
    kv "Namespaces"   "$ns_count"

    # Node readiness
    local not_ready
    not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready" | wc -l | tr -d ' ')
    [[ "$not_ready" -gt 0 ]] \
      && print_status 1 "Not-Ready nodes: $not_ready" \
      || print_status 0 "All nodes Ready"
  fi

  # Helm
  if command -v helm &>/dev/null; then
    local helm_version releases
    helm_version=$(helm version --short 2>/dev/null | tr -d '"')
    releases=$(helm list --all-namespaces --short 2>/dev/null | wc -l | tr -d ' ')
    print_status 0 "Helm available" "$helm_version"
    kv "Helm releases"   "$releases (all namespaces)"

    # Any failed releases?
    local failed_releases
    failed_releases=$(helm list --all-namespaces --failed --short 2>/dev/null | wc -l | tr -d ' ')
    [[ "$failed_releases" -gt 0 ]] \
      && print_status 1 "Failed Helm releases: $failed_releases" \
      || print_status 0 "No failed Helm releases"
  fi

  # ArgoCD
  if [[ -n "${ARGOCD_SERVER:-}" || command -v argocd &>/dev/null ]]; then
    print_status 0 "ArgoCD context detected"
    kv "ArgoCD server" "${ARGOCD_SERVER:-N/A}"
    if command -v argocd &>/dev/null && argocd app list &>/dev/null 2>&1; then
      local app_count outofsync_count
      app_count=$(argocd app list -o name 2>/dev/null | wc -l | tr -d ' ')
      outofsync_count=$(argocd app list 2>/dev/null | grep -c "OutOfSync" || true)
      kv "Apps"         "$app_count"
      [[ "$outofsync_count" -gt 0 ]] \
        && print_status 1 "OutOfSync apps: $outofsync_count" \
        || print_status 0 "All apps Synced"
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────
# SECTION: AWS ENVIRONMENT
# ─────────────────────────────────────────────────────────────────
section_aws() {
  section_enabled aws || return 0
  print_section "☁️   AWS ENVIRONMENT"

  # Detect execution context
  local ctx="local"
  [[ -n "${KUBERNETES_SERVICE_HOST:-}" ]] && ctx="EKS Pod"
  [[ -n "${ECS_CONTAINER_METADATA_URI:-}" ]] && ctx="ECS Task"
  [[ -n "${AWS_LAMBDA_FUNCTION_NAME:-}" ]] && ctx="Lambda"
  [[ -f "/sys/hypervisor/uuid" ]] && grep -qi "^ec2" /sys/hypervisor/uuid 2>/dev/null && ctx="EC2"

  kv "Execution context" "$ctx"

  # Fetch EC2 instance metadata (IMDSv2)
  local imds_token imds_ok=false
  imds_token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
    --connect-timeout 1 2>/dev/null) && imds_ok=true

  if $imds_ok && [[ -n "$imds_token" ]]; then
    _imds() { curl -s -H "X-aws-ec2-metadata-token: $imds_token" \
      "http://169.254.169.254/latest/meta-data/$1" --connect-timeout 1 2>/dev/null; }

    print_status 0 "EC2 IMDS reachable (IMDSv2)"
    kv "Instance ID"    "$(_imds instance-id)"
    kv "Instance type"  "$(_imds instance-type)"
    kv "Region"         "$(_imds placement/region)"
    kv "AZ"             "$(_imds placement/availability-zone)"
    kv "AMI ID"         "$(_imds ami-id)"
    kv "IAM role"       "$(_imds iam/security-credentials/ | head -1)"
    kv "Private IP"     "$(_imds local-ipv4)"
    kv "VPC ID"         "$(_imds network/interfaces/macs/$(_imds mac)/vpc-id 2>/dev/null || echo 'N/A')"
  else
    print_status 2 "EC2 IMDS not reachable (non-EC2 or IMDSv2 disabled)"
  fi

  # ECS metadata
  if [[ -n "${ECS_CONTAINER_METADATA_URI_V4:-}" ]]; then
    print_status 0 "ECS container metadata available (v4)"
    local ecs_meta
    ecs_meta=$(curl -s "${ECS_CONTAINER_METADATA_URI_V4}/task" --connect-timeout 2 2>/dev/null)
    if [[ -n "$ecs_meta" ]]; then
      kv "Cluster"        "$(echo "$ecs_meta" | jq -r '.Cluster // "N/A"' 2>/dev/null)"
      kv "Task ARN"       "$(echo "$ecs_meta" | jq -r '.TaskARN // "N/A"' 2>/dev/null)"
      kv "Family"         "$(echo "$ecs_meta" | jq -r '.Family // "N/A"' 2>/dev/null)"
    fi
  fi

  # Lambda
  if [[ -n "${AWS_LAMBDA_FUNCTION_NAME:-}" ]]; then
    print_status 0 "Lambda execution environment"
    kv "Function"       "$AWS_LAMBDA_FUNCTION_NAME"
    kv "Version"        "${AWS_LAMBDA_FUNCTION_VERSION:-N/A}"
    kv "Memory (MB)"    "${AWS_LAMBDA_FUNCTION_MEMORY_SIZE:-N/A}"
    kv "Runtime dir"    "${LAMBDA_RUNTIME_DIR:-N/A}"
  fi

  # AWS CLI / credentials
  if command -v aws &>/dev/null; then
    local caller_id
    caller_id=$(aws sts get-caller-identity --output json 2>/dev/null)
    if [[ -n "$caller_id" ]]; then
      print_status 0 "AWS credentials valid (STS)"
      kv "Account"      "$(echo "$caller_id" | jq -r '.Account' 2>/dev/null)"
      kv "ARN"          "$(echo "$caller_id" | jq -r '.Arn' 2>/dev/null)"
      kv "UserID"       "$(echo "$caller_id" | jq -r '.UserId' 2>/dev/null)"
      kv "Region"       "${AWS_DEFAULT_REGION:-${AWS_REGION:-not set}}"
    else
      print_status 1 "AWS credentials invalid or not configured"
    fi
  else
    print_status 2 "AWS CLI not installed"
  fi
}

# ─────────────────────────────────────────────────────────────────
# SECTION: GITHUB TOKEN
# ─────────────────────────────────────────────────────────────────
section_github() {
  section_enabled github || return 0
  print_section "🐙  GITHUB TOKEN"

  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    print_status 2 "GITHUB_TOKEN not set"
    return
  fi

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/user 2>/dev/null)

  if [[ "$http_code" == "200" ]]; then
    local info
    info=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" https://api.github.com/user 2>/dev/null)

    print_status 0 "Token valid"
    kv "Username"     "$(echo "$info" | jq -r '.login' 2>/dev/null)"
    kv "Name"         "$(echo "$info" | jq -r '.name' 2>/dev/null)"
    kv "Created"      "$(echo "$info" | jq -r '.created_at' 2>/dev/null)"
    kv "Plan"         "$(echo "$info" | jq -r '.plan.name // "N/A"' 2>/dev/null)"
    kv "2FA enabled"  "$(echo "$info" | jq -r '.two_factor_authentication' 2>/dev/null)"

    # Scopes
    local scopes
    scopes=$(curl -sI -H "Authorization: Bearer $GITHUB_TOKEN" \
      https://api.github.com/user 2>/dev/null | grep -i "^x-oauth-scopes" | cut -d: -f2- | tr -d ' \r')
    kv "Token scopes" "${scopes:-N/A}"

    # Repo count (approximate)
    local repo_count
    repo_count=$(echo "$info" | jq -r '.public_repos // 0' 2>/dev/null)
    kv "Public repos"  "$repo_count"

    # Rate limit
    local rl
    rl=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/rate_limit 2>/dev/null)
    local rl_remaining rl_limit rl_reset
    rl_remaining=$(echo "$rl" | jq -r '.rate.remaining' 2>/dev/null)
    rl_limit=$(echo "$rl" | jq -r '.rate.limit' 2>/dev/null)
    rl_reset=$(echo "$rl" | jq -r '.rate.reset' 2>/dev/null)
    rl_reset_human=$(date -d "@${rl_reset}" '+%H:%M:%S' 2>/dev/null || date -r "$rl_reset" '+%H:%M:%S' 2>/dev/null || echo "N/A")
    local pct=$(( (rl_remaining * 100) / (rl_limit + 1) ))
    local rl_color=""
    [[ $pct -lt 20 ]] && rl_color="$RED"
    [[ $pct -lt 50 && $pct -ge 20 ]] && rl_color="$YELLOW"
    kv "Rate limit"   "${rl_remaining}/${rl_limit} (resets ${rl_reset_human})" "$rl_color"

    # Token expiry (fine-grained PAT)
    local expiry
    expiry=$(curl -sI -H "Authorization: Bearer $GITHUB_TOKEN" \
      https://api.github.com/user 2>/dev/null | grep -i "github-authentication-token-expiration" | cut -d: -f2- | tr -d ' \r')
    [[ -n "$expiry" ]] && kv "Token expires" "$expiry"
  elif [[ "$http_code" == "401" ]]; then
    print_status 1 "Token invalid or expired (HTTP 401)"
  elif [[ "$http_code" == "403" ]]; then
    print_status 1 "Token forbidden (HTTP 403) — may lack required scopes"
  else
    print_status 1 "Unexpected HTTP $http_code from GitHub API"
  fi
}

# ─────────────────────────────────────────────────────────────────
# SECTION: DOCKER
# ─────────────────────────────────────────────────────────────────
section_docker() {
  section_enabled docker || return 0
  print_section "🐳  DOCKER"

  # Docker daemon
  if command -v docker &>/dev/null; then
    if docker info &>/dev/null 2>&1; then
      local d_info
      d_info=$(docker info --format '{{json .}}' 2>/dev/null)
      print_status 0 "Docker daemon running"
      kv "Engine version"  "$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
      kv "OS/Arch"         "$(echo "$d_info" | jq -r '"\(.OSType)/\(.Architecture)"' 2>/dev/null)"
      kv "Containers"      "$(echo "$d_info" | jq -r '"\(.Containers) total (\(.ContainersRunning) running)"' 2>/dev/null)"
      kv "Images"          "$(echo "$d_info" | jq -r '.Images' 2>/dev/null)"
      kv "Storage driver"  "$(echo "$d_info" | jq -r '.Driver' 2>/dev/null)"
      kv "Root dir"        "$(echo "$d_info" | jq -r '.DockerRootDir' 2>/dev/null)"

      # Dangling images (wasted space)
      local dangling
      dangling=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l | tr -d ' ')
      [[ "$dangling" -gt 0 ]] \
        && print_status 2 "Dangling images: $dangling (run: docker image prune)" \
        || print_status 0 "No dangling images"

      # Kaniko detection
      if [[ -n "${KANIKO_DIR:-}" ]] || ls /kaniko &>/dev/null 2>&1; then
        print_status 0 "Kaniko build environment detected"
        kv "Kaniko executor" "$(which executor 2>/dev/null || echo 'N/A')"
      fi

      # BuildKit
      if [[ "${DOCKER_BUILDKIT:-}" == "1" ]]; then
        print_status 0 "BuildKit enabled (DOCKER_BUILDKIT=1)"
      else
        print_status 2 "BuildKit not explicitly enabled (set DOCKER_BUILDKIT=1 for faster builds)"
      fi
    else
      print_status 1 "Docker daemon not running or permission denied"
    fi
  else
    print_status 1 "Docker not installed"
  fi

  # Docker Hub credentials
  if [[ -n "${DOCKER_USER:-}" && -n "${DOCKER_PASS:-}" ]]; then
    local dh_code
    dh_code=$(curl -s -o /dev/null -w "%{http_code}" \
      -u "$DOCKER_USER:$DOCKER_PASS" \
      "https://hub.docker.com/v2/users/$DOCKER_USER/" 2>/dev/null)

    if [[ "$dh_code" == "200" ]]; then
      local dh_info
      dh_info=$(curl -s -u "$DOCKER_USER:$DOCKER_PASS" \
        "https://hub.docker.com/v2/users/$DOCKER_USER/" 2>/dev/null)
      print_status 0 "Docker Hub credentials valid"
      kv "Username"    "$DOCKER_USER"
      kv "Joined"      "$(echo "$dh_info" | grep -o '"date_joined":"[^"]*' | cut -d'"' -f4)"
      local repo_c
      repo_c=$(curl -s -u "$DOCKER_USER:$DOCKER_PASS" \
        "https://hub.docker.com/v2/repositories/$DOCKER_USER/?page_size=1" 2>/dev/null \
        | grep -o '"count":[0-9]*' | grep -o '[0-9]*')
      kv "Repositories" "${repo_c:-0}"
    else
      print_status 1 "Docker Hub credentials invalid (HTTP $dh_code)"
    fi
  else
    print_status 2 "DOCKER_USER / DOCKER_PASS not set"
  fi
}

# ─────────────────────────────────────────────────────────────────
# SECTION: JFROG ARTIFACTORY
# ─────────────────────────────────────────────────────────────────
section_jfrog() {
  section_enabled jfrog || return 0
  print_section "📦  JFROG ARTIFACTORY"

  local url="${ARTIFACTORY_URL:-}"
  local token="${ARTIFACTORY_TOKEN:-}"
  local user="${ARTIFACTORY_USER:-}"
  local pass="${ARTIFACTORY_PASS:-}"

  if [[ -z "$url" ]]; then
    print_status 2 "ARTIFACTORY_URL not set — skipping Artifactory checks"
    return
  fi

  # Prefer token auth; fall back to basic
  local auth_header
  if [[ -n "$token" ]]; then
    auth_header="Authorization: Bearer $token"
  elif [[ -n "$user" && -n "$pass" ]]; then
    auth_header="Authorization: Basic $(echo -n "$user:$pass" | base64)"
  else
    print_status 2 "No Artifactory credentials (ARTIFACTORY_TOKEN or ARTIFACTORY_USER/PASS)"
    return
  fi

  local sys_code
  sys_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "$auth_header" "${url%/}/api/system/ping" \
    --connect-timeout 5 2>/dev/null)

  if [[ "$sys_code" == "200" ]]; then
    print_status 0 "Artifactory reachable and credentials valid"
    kv "URL"     "$url"

    # Version
    local version
    version=$(curl -s -H "$auth_header" "${url%/}/api/system/version" \
      --connect-timeout 5 2>/dev/null | jq -r '.version // "N/A"' 2>/dev/null)
    kv "Version" "$version"

    # List repos (first 5)
    local repos
    repos=$(curl -s -H "$auth_header" "${url%/}/api/repositories" \
      --connect-timeout 5 2>/dev/null \
      | jq -r '.[].key' 2>/dev/null | head -5 | tr '\n' '  ')
    kv "Repos (sample)" "${repos:-N/A}"

    # Storage summary
    local storage
    storage=$(curl -s -H "$auth_header" "${url%/}/api/storageinfo" \
      --connect-timeout 5 2>/dev/null)
    if [[ -n "$storage" ]]; then
      kv "Storage used"     "$(echo "$storage" | jq -r '.fileStoreSummary.usedSpace // "N/A"' 2>/dev/null)"
      kv "Storage total"    "$(echo "$storage" | jq -r '.fileStoreSummary.totalSpace // "N/A"' 2>/dev/null)"
    fi
  elif [[ "$sys_code" == "401" ]]; then
    print_status 1 "Artifactory credentials invalid (HTTP 401)"
  elif [[ "$sys_code" == "000" ]]; then
    print_status 1 "Artifactory unreachable (connection timeout/refused): $url"
  else
    print_status 1 "Artifactory returned HTTP $sys_code"
  fi
}

# ─────────────────────────────────────────────────────────────────
# SECTION: GERRIT
# ─────────────────────────────────────────────────────────────────
section_gerrit() {
  section_enabled gerrit || return 0
  print_section "🔁  GERRIT CODE REVIEW"

  local url="${GERRIT_URL:-}"
  local user="${GERRIT_USER:-}"
  local pass="${GERRIT_HTTP_PASS:-}"

  if [[ -z "$url" ]]; then
    print_status 2 "GERRIT_URL not set — skipping Gerrit checks"
    return
  fi

  # Gerrit REST API uses digest auth; /a/ prefix = authenticated
  local version_code
  version_code=$(curl -s -o /dev/null -w "%{http_code}" \
    "${url%/}/config/server/version" --connect-timeout 5 2>/dev/null)

  if [[ "$version_code" == "200" ]]; then
    local version
    version=$(curl -s "${url%/}/config/server/version" \
      --connect-timeout 5 2>/dev/null | sed "s/)]}')//; s/\"//g" | tr -d '\n')
    print_status 0 "Gerrit reachable (anonymous)"
    kv "URL"     "$url"
    kv "Version" "${version:-N/A}"

    if [[ -n "$user" && -n "$pass" ]]; then
      # Authenticated call to get user info
      local auth_code
      auth_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --digest -u "$user:$pass" \
        "${url%/}/a/accounts/self" --connect-timeout 5 2>/dev/null)

      if [[ "$auth_code" == "200" ]]; then
        local me
        me=$(curl -s --digest -u "$user:$pass" \
          "${url%/}/a/accounts/self" --connect-timeout 5 2>/dev/null \
          | sed "s/)]}')//")
        print_status 0 "Authenticated to Gerrit"
        kv "Account"      "$(echo "$me" | jq -r '.username' 2>/dev/null)"
        kv "Email"        "$(echo "$me" | jq -r '.email' 2>/dev/null)"
        kv "Display name" "$(echo "$me" | jq -r '.display_name' 2>/dev/null)"

        # Open changes assigned to this user
        local open_changes
        open_changes=$(curl -s --digest -u "$user:$pass" \
          "${url%/}/a/changes/?q=assignee:self+status:open&n=5" \
          --connect-timeout 5 2>/dev/null | sed "s/)]}'//" | jq '. | length' 2>/dev/null)
        kv "Open changes (assignee)" "${open_changes:-0}"
      else
        print_status 2 "Gerrit authentication failed (HTTP $auth_code) — check GERRIT_USER/GERRIT_HTTP_PASS"
      fi
    else
      print_status 2 "GERRIT_USER / GERRIT_HTTP_PASS not set — only anonymous checks run"
    fi
  elif [[ "$version_code" == "000" ]]; then
    print_status 1 "Gerrit unreachable: $url"
  else
    print_status 1 "Gerrit returned HTTP $version_code"
  fi
}

# ─────────────────────────────────────────────────────────────────
# SECTION: SYSTEM RESOURCES
# ─────────────────────────────────────────────────────────────────
section_resources() {
  section_enabled resources || return 0
  print_section "📊  SYSTEM RESOURCES"

  # CPU
  local cpu_model cores load_1 load_5 load_15 load_per_core_1
  cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || lscpu 2>/dev/null | grep 'Model name' | cut -d: -f2 | xargs)
  cores=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
  IFS=' ' read -r load_1 load_5 load_15 _ < /proc/loadavg 2>/dev/null || { load_1=0; load_5=0; load_15=0; }
  load_per_core_1=$(echo "scale=2; $load_1 / $cores" | bc -l)

  local load_status
  load_status=$(threshold_status "$load_per_core_1" "$LOAD_WARN_THRESHOLD" "$(echo "$LOAD_WARN_THRESHOLD * 2" | bc -l)")
  kv "CPU model"     "$cpu_model"
  kv "CPU cores"     "$cores"
  local load_color=""
  [[ "$load_status" -eq 1 ]] && load_color="$RED"
  [[ "$load_status" -eq 2 ]] && load_color="$YELLOW"
  kv "Load avg"      "${load_1} / ${load_5} / ${load_15}  (per-core: ${load_per_core_1})" "$load_color"
  print_status "$load_status" "CPU load ${load_per_core_1}x per core (1-min)"

  # Memory
  local mem_total mem_used mem_avail mem_pct
  if [[ -f /proc/meminfo ]]; then
    mem_total=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    mem_avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    mem_used=$(( mem_total - mem_avail ))
    mem_pct=$(echo "scale=0; $mem_used * 100 / $mem_total" | bc)
    local mem_human_used mem_human_total
    mem_human_used=$(free -h | awk '/Mem/{print $3}')
    mem_human_total=$(free -h | awk '/Mem/{print $2}')
    local mem_status mem_color=""
    mem_status=$(threshold_status "$mem_pct" "$MEM_WARN_THRESHOLD" "$MEM_CRIT_THRESHOLD")
    [[ "$mem_status" -eq 1 ]] && mem_color="$RED"
    [[ "$mem_status" -eq 2 ]] && mem_color="$YELLOW"
    kv "Memory"        "${mem_human_used} / ${mem_human_total} (${mem_pct}% used)" "$mem_color"
    print_status "$mem_status" "Memory usage at ${mem_pct}%"
  fi

  # Disk (all mounted filesystems)
  echo "" | _tee
  df -h --output=source,fstype,size,used,avail,pcent,target 2>/dev/null \
    | grep -v '^tmpfs\|^overlay\|^devtmpfs\|^udev\|^Filesystem' \
    | while IFS= read -r line; do
        local pct mount
        pct=$(echo "$line" | awk '{print $6}' | tr -d '%')
        mount=$(echo "$line" | awk '{print $7}')
        [[ "$mount" == "/snap"* ]] && continue
        local disk_status disk_color=""
        disk_status=$(threshold_status "${pct:-0}" "$DISK_WARN_THRESHOLD" "$DISK_CRIT_THRESHOLD")
        [[ "$disk_status" -eq 1 ]] && disk_color="$RED"
        [[ "$disk_status" -eq 2 ]] && disk_color="$YELLOW"
        kv "Disk [$mount]" "$(echo "$line" | awk '{print $4 " / " $3 " (" $6 " used)"}')" "$disk_color"
        [[ "$disk_status" -ne 0 ]] && print_status "$disk_status" "Disk usage at ${pct}% on $mount"
      done
}

# ─────────────────────────────────────────────────────────────────
# SECTION: TOOL VERSIONS
# ─────────────────────────────────────────────────────────────────
section_tools() {
  section_enabled tools || return 0
  print_section "🧰  TOOL VERSIONS"

  _check_tool() {
    local name="$1" version_cmd="$2"
    if command -v "$name" &>/dev/null; then
      local ver
      ver=$(eval "$version_cmd" 2>/dev/null | head -1 | sed 's/^[[:space:]]*//')
      print_status 0 "$name" "$ver"
    else
      print_status 1 "$name not found in PATH"
    fi
  }

  _check_tool git       "git --version"
  _check_tool docker    "docker --version"
  _check_tool kubectl   "kubectl version --client --short 2>/dev/null || kubectl version --client"
  _check_tool helm      "helm version --short"
  _check_tool terraform "terraform version | head -1"
  _check_tool ansible   "ansible --version | head -1"
  _check_tool jq        "jq --version"
  _check_tool curl      "curl --version | head -1"
  _check_tool aws       "aws --version"
  _check_tool trivy     "trivy --version | head -1"
  _check_tool kaniko    "executor version 2>/dev/null || echo 'executor binary (version N/A)'"
  _check_tool argocd    "argocd version --client --short 2>/dev/null || argocd version --client | head -1"
  _check_tool skaffold  "skaffold version"
  _check_tool kustomize "kustomize version"
  _check_tool vault     "vault version"
  _check_tool python3   "python3 --version"
  _check_tool node      "node --version"
}

# ─────────────────────────────────────────────────────────────────
# SECTION: NETWORK CONNECTIVITY
# ─────────────────────────────────────────────────────────────────
section_network() {
  section_enabled network || return 0
  print_section "🌐  NETWORK CONNECTIVITY"

  # DNS resolution
  for host in google.com github.com; do
    if getent hosts "$host" &>/dev/null 2>&1 || nslookup "$host" &>/dev/null 2>&1; then
      print_status 0 "DNS resolves $host"
    else
      print_status 1 "DNS failed for $host"
    fi
  done

  # ICMP ping
  for target in $NETWORK_HOSTS; do
    if ping -c 1 -W 2 "$target" &>/dev/null 2>&1; then
      local rtt
      rtt=$(ping -c 1 -W 2 "$target" 2>/dev/null | grep 'time=' | grep -o 'time=[0-9.]*' | cut -d= -f2)
      print_status 0 "Ping $target" "${rtt}ms"
    else
      print_status 1 "Ping $target unreachable"
    fi
  done

  # TCP port checks  (PORT_CHECKS="github.com:443 myregistry:5000")
  for check in $PORT_CHECKS; do
    local h p
    h="${check%:*}"; p="${check#*:}"
    if timeout 3 bash -c ">/dev/tcp/$h/$p" &>/dev/null 2>&1; then
      print_status 0 "TCP $h:$p open"
    else
      print_status 1 "TCP $h:$p unreachable"
    fi
  done

  # Default gateway
  local gw
  gw=$(ip route 2>/dev/null | awk '/default/{print $3; exit}' || route -n 2>/dev/null | awk '/UG/{print $2; exit}')
  [[ -n "$gw" ]] && kv "Default gateway" "$gw"

  # Public IP
  local pub_ip
  pub_ip=$(curl -s --connect-timeout 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '\n')
  [[ -n "$pub_ip" ]] && kv "Public IP" "$pub_ip"
}

# ─────────────────────────────────────────────────────────────────
# SECTION: SSL CERTIFICATE EXPIRY
# ─────────────────────────────────────────────────────────────────
section_ssl() {
  section_enabled ssl || return 0
  [[ -z "$SSL_DOMAINS" ]] && return 0    # skip if no domains configured

  print_section "🔐  SSL CERTIFICATES"

  for domain in $SSL_DOMAINS; do
    local host port="${domain##*:}"
    host="${domain%:*}"
    [[ "$port" == "$host" ]] && port=443   # default

    local expiry_raw expiry_epoch days_left
    expiry_raw=$(echo | timeout 5 openssl s_client -servername "$host" -connect "$host:$port" 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

    if [[ -z "$expiry_raw" ]]; then
      print_status 1 "Could not retrieve cert for $host:$port"
      continue
    fi

    expiry_epoch=$(date -d "$expiry_raw" +%s 2>/dev/null || date -jf "%b %d %T %Y %Z" "$expiry_raw" +%s 2>/dev/null)
    days_left=$(( (expiry_epoch - $(date +%s)) / 86400 ))

    if   [[ $days_left -le 7  ]]; then
      print_status 1 "CERT CRITICAL $host — expires in ${days_left}d ($expiry_raw)"
    elif [[ $days_left -le $SSL_WARN_DAYS ]]; then
      print_status 2 "Cert expiring soon: $host — ${days_left}d left"
    else
      print_status 0 "Cert valid: $host" "${days_left} days remaining"
    fi
    kv "Expiry [$host]"   "$expiry_raw"
  done
}

# ─────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────
main() {
  # Header
  [[ -n "$LOG_FILE" ]] && : > "$LOG_FILE"   # truncate log

  print_double_line
  echo -e "${BOLD}${MAGENTA}  🚀  RAJA DEVOPS DASHBOARD${RESET}" | _tee
  echo -e "${DIM}  $(date '+%A, %d %B %Y — %H:%M:%S %Z')${RESET}" | _tee
  print_double_line

  section_system

  # Run sections (sequentially; swap to background+spinner pattern below for speed)
  section_git
  section_cicd
  section_k8s
  section_aws
  section_github
  section_docker
  section_jfrog
  section_gerrit
  section_resources
  section_tools
  section_network
  section_ssl

  # ── SUMMARY ───────────────────────────────────────────────────
  local end_time elapsed
  end_time=$(date +%s)
  elapsed=$((end_time - start_time))

  print_double_line
  print_section "📌  SUMMARY"

  kv "✔  Passed"     "$PASSED" "$GREEN"
  kv "⚠  Warnings"   "$WARN"   "$YELLOW"
  kv "✖  Failed"     "$FAILED" "$([[ $FAILED -gt 0 ]] && echo "$RED" || echo "")"
  kv "⏱  Duration"   "${elapsed}s"
  [[ -n "$LOG_FILE" ]] && kv "📄  Log saved"  "$LOG_FILE"

  print_double_line

  if $EXIT_ON_FAIL && [[ $FAILED -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
