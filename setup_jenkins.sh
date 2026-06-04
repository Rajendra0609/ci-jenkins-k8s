#!/bin/bash

# setup_jenkins.sh
# ----------------
# This script applies all Kubernetes YAML manifests in this directory to the
# `jenkins` namespace and extracts the service account token. It now prints an
# advanced startup banner with environment/context hints. To disable the banner
# set the environment variable SKIP_BANNER=1 before running this script:
#
#   SKIP_BANNER=1 ./setup_jenkins.sh
#
# Banner features:
# - Colored ASCII-art header
# - UTC timestamp and host
# - Current kubectl context and cluster (if kubectl is available)
# - Checks for presence of kubectl and helm
# - Suggested next steps and a brief tip to tail Jenkins logs
# The banner is intentionally read-only and doesn't change any cluster state.

# Advanced startup banner (opt-out with SKIP_BANNER=1)
if [ -z "$SKIP_BANNER" ]; then
  # Colors (supports typical terminals)
  NC="\e[0m"
  BOLD="\e[1m"
  RED="\e[31m"
  GREEN="\e[32m"
  YELLOW="\e[33m"
  CYAN="\e[36m"

  # Basic info
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  HOSTNAME=$(hostname 2>/dev/null || echo "unknown-host")
  KUBECTL_AVAILABLE=0
  if command -v kubectl >/dev/null 2>&1; then
    KUBECTL_AVAILABLE=1
    KUBE_CTX=$(kubectl config current-context 2>/dev/null || echo "(no-context)")
    KUBE_CLUSTER=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || echo "(no-cluster)")
  else
    KUBE_CTX="kubectl:not-found"
    KUBE_CLUSTER="kubectl:not-found"
  fi

  HELM_AVAILABLE=0
  if command -v helm >/dev/null 2>&1; then
    HELM_AVAILABLE=1
  fi

  # ASCII banner (kept reasonably wide)
  echo -e "${CYAN}${BOLD}====================================================================${NC}"
  echo -e "${CYAN}${BOLD}  _     _             _             _           _                  ${NC}"
  echo -e "${CYAN}${BOLD} | |   (_)           | |           | |         | |                 ${NC}"
  echo -e "${CYAN}${BOLD} | | __ _ _ __   __ _| |_ ___  _ __| |_ ___  __| | ___  _ __ ___  ${NC}"
  echo -e "${CYAN}${BOLD} | |/ /| | '_ \\ / _\` | __/ _ \\| '__| __/ _ \\/ _\` |/ _ \\| '__/ _ \\ ${NC}"
  echo -e "${CYAN}${BOLD} |   < | | | | | (_| | || (_) | |  | ||  __/ (_| | (_) | | |  __/ ${NC}"
  echo -e "${CYAN}${BOLD} |_|\\_\\|_|_| |_|\\__,_|\\__\\___/|_|   \\__\\___|\\__,_|\\___/|_|  \\___| ${NC}"
  echo -e "${CYAN}${BOLD}====================================================================${NC}"
  echo -e "${BOLD}Time:${NC} ${TIMESTAMP}    ${BOLD}Host:${NC} ${HOSTNAME}"
  echo -e "${BOLD}Kube Context:${NC} ${KUBE_CTX}    ${BOLD}Cluster:${NC} ${KUBE_CLUSTER}"
  echo -e "${BOLD}kubectl:${NC} $( [ $KUBECTL_AVAILABLE -eq 1 ] && echo "${GREEN}available${NC}" || echo "${RED}missing${NC}" )    ${BOLD}helm:${NC} $( [ $HELM_AVAILABLE -eq 1 ] && echo "${GREEN}available${NC}" || echo "${YELLOW}not-found${NC}" )"
  echo -e "${YELLOW}Suggested next steps:${NC} 1) Verify kubectl context; 2) Review applied YAML files; 3) Tail Jenkins logs with 'kubectl -n jenkins logs -l app.kubernetes.io/name=jenkins --follow'"
  echo -e "${CYAN}Tip: To skip this banner set environment variable ${BOLD}SKIP_BANNER=1${NC}"
  echo
fi

# Create the jenkins namespace if it doesn't exist
kubectl get namespace jenkins >/dev/null 2>&1 || kubectl create namespace jenkins

# Apply all YAML files in the current directory to the jenkins namespace
for file in *.yaml; do
  if [ "$file" != "jenkins-sa-token.yaml" ]; then
    echo "Applying $file to namespace jenkins"
    kubectl apply -f "$file" -n jenkins
    echo "Applied $file"
  fi
done

# Apply jenkins-sa-token.yaml separately
echo "Applying jenkins-sa-token.yaml to namespace jenkins"
kubectl apply -f jenkins-sa-token.yaml

# Extract and display the token
echo "
Add this token to the Jenkins Cloud Kubernetes credential to get authenticated:"
kubectl -n jenkins get secret jenkins-sa-token -o jsonpath='{.data.token}' | base64 --decode

echo "
Token extraction complete."
kubectl create secret tls jenkins-tls --key tls.key --cert tls.crt -n jenkins

patch.sh
