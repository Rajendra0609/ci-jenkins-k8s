#!/bin/bash

# Colors
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
MAGENTA="\e[35m"
RESET="\e[0m"
BOLD="\e[1m"

start_time=$(date +%s)
PASSED=0
FAILED=0
WARN=0

print_line() {
  echo -e "${CYAN}============================================================${RESET}"
}

print_box() {
  local msg="$1"
  echo -e "${BOLD}${MAGENTA}💠 $msg${RESET}"
}

print_status() {
  local status=$1
  local message="$2"
  if [ "$status" -eq 0 ]; then
    echo -e "   ✔ ${GREEN}$message${RESET}"
    PASSED=$((PASSED+1))
  elif [ "$status" -eq 2 ]; then
    echo -e "   ⚠️ ${YELLOW}$message${RESET}"
    WARN=$((WARN+1))
  else
    echo -e "   ❌ ${RED}$message${RESET}"
    FAILED=$((FAILED+1))
  fi
}

print_key_value() {
  local key="$1"
  local value="$2"
  printf "   %-20s : %s\n" "$key" "$value"
}

#############################################
# START DASHBOARD
#############################################
print_line
print_box "🚀 WELCOME TO RAJA TECH DASHBOARD"
print_line

#############################################
# SYSTEM INFO
#############################################
print_box "💻 SYSTEM INFO"
print_key_value "Hostname" "$(hostname)"
print_key_value "User" "$(whoami)"

#############################################
# GIT PROJECT INFO
#############################################
git_root=$(git rev-parse --show-toplevel 2>/dev/null)
print_box "🌿 GIT PROJECT INFORMATION"
if [ -n "$git_root" ]; then
    print_key_value "Project Name" "$(basename "$git_root")"
    print_key_value "Branch" "$(git -C "$git_root" rev-parse --abbrev-ref HEAD)"
    print_key_value "Latest Commit By" "$(git -C "$git_root" log -1 --pretty=format:'%an')"
    print_key_value "Commit SHA" "$(git -C "$git_root" rev-parse HEAD)"
    print_key_value "Commit Message" "$(git -C "$git_root" log -1 --pretty=%B)"
    print_key_value "Commit Email" "$(git -C "$git_root" log -1 --pretty=format:'%ae')"
    print_key_value "Triggered By" "$(whoami)"
else
    print_status 1 "Not a git repository"
fi

#############################################
# CI/CD ENVIRONMENT
#############################################
print_box "🤖 CI/CD ENVIRONMENT"
if [ -n "$JENKINS_HOME" ]; then
    print_key_value "Type" "Jenkins"
    print_key_value "Job Name" "${JOB_NAME:-N/A}"
    print_key_value "Build Number" "${BUILD_NUMBER:-N/A}"
elif [ -n "$GITLAB_CI" ]; then
    print_key_value "Type" "GitLab CI"
elif [ -n "$GITHUB_ACTIONS" ]; then
    print_key_value "Type" "GitHub Actions"
else
    print_status 2 "Not running in recognized CI/CD"
fi

#############################################
# KUBERNETES ENVIRONMENT
#############################################
print_box "☸️ KUBERNETES ENVIRONMENT"
if [ -n "$KUBERNETES_SERVICE_HOST" ]; then
    print_key_value "Pod Name" "$HOSTNAME"
    print_key_value "Namespace" "${POD_NAMESPACE:-default}"
    print_key_value "Pod IP" "$(hostname -i)"
else
    print_status 2 "Not running in Kubernetes"
fi

#############################################
# GITHUB TOKEN
#############################################
print_box "🐙 GITHUB TOKEN INFO"
if [ -n "$GITHUB_TOKEN" ]; then
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/user)
    if [ "$http_code" -eq 200 ]; then
        github_info=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/user)
        github_username=$(echo "$github_info" | grep '"login":' | cut -d '"' -f 4)
        github_created=$(echo "$github_info" | grep '"created_at":' | cut -d '"' -f 4)
        repo_count=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "https://api.github.com/user/repos?per_page=1" \
                     | grep -c '"full_name"')
        print_status 0 "GitHub Token Valid"
        print_key_value "Username" "$github_username"
        print_key_value "Created At" "$github_created"
        print_key_value "Repo Count" "$repo_count"
    else
        print_status 1 "Invalid GitHub Token (HTTP $http_code)"
    fi
else
    print_status 2 "GitHub token not set"
fi

#############################################
# DOCKER TOKEN
#############################################
print_box "🐳 DOCKER HUB TOKEN INFO"
if [ -n "$DOCKER_USER" ] && [ -n "$DOCKER_PASS" ]; then
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -u "$DOCKER_USER:$DOCKER_PASS" https://hub.docker.com/v2/users/$DOCKER_USER/)
    if [ "$http_code" -eq 200 ]; then
        print_status 0 "Docker Token Valid"
        print_key_value "Username" "$DOCKER_USER"
        repo_count=$(curl -s -u "$DOCKER_USER:$DOCKER_PASS" "https://hub.docker.com/v2/repositories/$DOCKER_USER/?page_size=1" \
                     | grep -o '"count":[0-9]*' | grep -o '[0-9]*')
        join_date=$(curl -s -u "$DOCKER_USER:$DOCKER_PASS" "https://hub.docker.com/v2/users/$DOCKER_USER/" \
                     | grep -o '"date_joined":"[^"]*' | cut -d':' -f2- | tr -d '"')
        print_key_value "Repos" "$repo_count"
        print_key_value "Joined At" "$join_date"
    else
        print_status 1 "Invalid Docker Credentials (HTTP $http_code)"
    fi
else
    print_status 2 "Docker credentials not set"
fi

#############################################
# SYSTEM RESOURCES
#############################################
print_box "📊 SYSTEM RESOURCE INFO"
print_key_value "Memory Usage" "$(free -h | awk '/Mem:/ {print $3 "/" $2}')"
print_key_value "CPU Info" "$(lscpu | grep 'Model name' | cut -d ':' -f2 | xargs)"
print_key_value "Load Average" "$(uptime | awk -F 'load average:' '{print $2}')"
print_key_value "Disk Usage" "$(df -h / | awk 'NR==2{print $3 "/" $2 " (" $5 ")"}')"

#############################################
# TOOL VERIFICATION
#############################################
print_box "🧪 TOOL VERIFICATION"
for tool in git curl docker kubectl jq; do
  if command -v $tool &>/dev/null; then
    print_status 0 "$tool installed"
  else
    print_status 1 "$tool missing"
  fi
done

#############################################
# SCRIPT RUNTIME
#############################################
end_time=$(date +%s)
print_box "⏱️ SCRIPT RUNTIME"
print_key_value "Total Time" "$((end_time - start_time)) seconds"

#############################################
# SUMMARY
#############################################
print_line
print_box "📌 SUMMARY"
print_key_value "✔ Checks Passed" "$PASSED"
print_key_value "⚠️ Warnings" "$WARN"
print_key_value "❌ Checks Failed" "$FAILED"
print_line
