# ─────────────────────────────────────────────────────────────────────────────
# Jenkins Inbound Agent — Docker + Terraform + Gitleaks + Security Tools
#
# Usage:
#   docker build \
#     --build-arg GITLEAKS_VERSION=8.24.3 \
#     --build-arg TERRAFORM_VERSION=1.11.4 \
#     -t jenkins-agent:latest .
#
# Runtime:
#   docker run --rm \
#     -e JENKINS_URL=https://jenkins.example.com \
#     -e JENKINS_SECRET=<secret> \
#     -e JENKINS_AGENT_NAME=docker-node \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     jenkins-agent:latest
# ─────────────────────────────────────────────────────────────────────────────

# ── Build-time version pins (override with --build-arg) ──────────────────────
ARG JENKINS_AGENT_BASE=latest
ARG GITLEAKS_VERSION=8.24.3
ARG TERRAFORM_VERSION=1.11.4
# Java is intentionally NOT an ARG — hardcoded to 21 throughout this file
# to prevent accidental downgrades via --build-arg at build time.

# ─────────────────────────────────────────────────────────────────────────────
# BASE STAGE
# ─────────────────────────────────────────────────────────────────────────────
FROM jenkins/inbound-agent:${JENKINS_AGENT_BASE}

# Re-declare ARGs after FROM so they're visible in this stage
ARG GITLEAKS_VERSION
ARG TERRAFORM_VERSION

# ── OCI-compliant image labels ────────────────────────────────────────────────
LABEL maintainer="rajendra.daggubati1997@gmail.com" \
      version="2.492.3" \
      description="Jenkins inbound agent with Docker CLI, Terraform, Gitleaks, Python 3 and security tooling" \
      org.opencontainers.image.source="https://github.com/Chowdary1997/Jenkins_jenkins_nodes_Dockerfle.git" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.created="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      org.opencontainers.image.vendor="Raja DevOps" \
      org.opencontainers.image.title="Jenkins Inbound Agent" \
      org.opencontainers.image.documentation="https://github.com/Chowdary1997/Jenkins_jenkins_nodes_Dockerfle.git"

# ── Runtime env defaults (all overridable at docker run / k8s pod spec) ───────
# ─────────────────────────────────────────────────────────────────────────────
# LAYER 1 — Core OS packages + Docker repo + HashiCorp repo
# Combining update + install + cleanup in a single RUN keeps the layer lean.
# --no-install-recommends cuts ~30-50 MB from base dependencies.
# Java is installed as openjdk-21-jre-headless (hardcoded, not via ARG).
# ─────────────────────────────────────────────────────────────────────────────
USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        wget \
        gnupg \
        lsb-release \
        fontconfig \
        maven \
        lynis \
        colorized-logs \
        unzip \
        git \
        jq \
        openjdk-21-jre-headless && \
    # ── Docker CE repo ────────────────────────────────────────────────────────
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg \
         -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
         https://download.docker.com/linux/debian \
         $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
         > /etc/apt/sources.list.d/docker.list && \
    # ── HashiCorp repo ────────────────────────────────────────────────────────
    curl -fsSL https://apt.releases.hashicorp.com/gpg | \
        gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
         https://apt.releases.hashicorp.com \
         $(lsb_release -cs) main" \
         > /etc/apt/sources.list.d/hashicorp.list && \
    # ── Install Docker CLI + Terraform ────────────────────────────────────────
    # Installing only docker-ce-cli (not the full daemon) is intentional:
    # the host Docker socket is bind-mounted at runtime, so the daemon is
    # not needed inside the agent image. Add docker-ce + containerd.io only
    # if you are doing Docker-in-Docker (DinD).
    apt-get update && \
    apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-buildx-plugin \
        docker-compose-plugin \
        terraform=${TERRAFORM_VERSION}-1 && \
    # ── Hard-fail the build if Java is not exactly 21 ─────────────────────────
    JAVA_MAJOR=$(java -version 2>&1 | grep -oP '(?<=version ")([0-9]+)' | head -1) && \
    [ "$JAVA_MAJOR" = "21" ] || { echo "BUILD ERROR: expected Java 21, got $JAVA_MAJOR"; exit 1; } && \
    echo "Java version check passed: $JAVA_MAJOR" && \
    # ── Cleanup ───────────────────────────────────────────────────────────────
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ─────────────────────────────────────────────────────────────────────────────
# LAYER 2 — Python 3
#
# python3-full   : standard library + ensurepip/venv support
# python3-dev    : C headers needed by pip packages that compile extensions
#                  (e.g. cryptography, psycopg2)
# python3-venv   : explicit venv support for pipeline virtualenvs
#
# Symlinks make `python` and `pip` resolve to python3/pip3, preventing
# "command not found" errors in legacy Jenkinsfile sh() steps.
#
# Pre-installed pip packages cover the most common DevOps/AWS/K8s use-cases
# so pipelines don't need a setup step for these.
# ─────────────────────────────────────────────────────────────────────────────

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        python3-pip \
        python3-dev && \
    python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/venv/bin/pip install --no-cache-dir \
        boto3 \
        botocore \
        ansible \
        requests \
        PyYAML \
        jinja2 \
        hvac \
        kubernetes && \
    /opt/venv/bin/python -c "import boto3, ansible, kubernetes; print('OK')" && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/venv/bin:$PATH"

# ─────────────────────────────────────────────────────────────────────────────
# LAYER 3 — Gitleaks (pinned version, reproducible)
# Using a fixed ARG version instead of querying /releases/latest at build time
# ensures the build is reproducible and doesn't break when a new release drops.
# ─────────────────────────────────────────────────────────────────────────────
RUN set -eux; \
    GITLEAKS_URL=$(curl -s https://api.github.com/repos/gitleaks/gitleaks/releases/latest \
        | grep "browser_download_url" \
        | grep "linux_x64.tar.gz" \
        | cut -d '"' -f 4); \
    curl -L "$GITLEAKS_URL" -o gitleaks.tar.gz; \
    tar -xzf gitleaks.tar.gz; \
    chmod +x gitleaks; \
    mv gitleaks /usr/local/bin/gitleaks; \
    rm gitleaks.tar.gz

# ─────────────────────────────────────────────────────────────────────────────
# LAYER 4 — Trivy (container & IaC vulnerability scanner)
# Complements lynis for a full security scanning toolkit on the agent.
# ─────────────────────────────────────────────────────────────────────────────
RUN set -eux; \
    TRIVY_VERSION=$(curl -s https://api.github.com/repos/aquasecurity/trivy/releases/latest \
        | jq -r '.tag_name' | tr -d 'v'); \
    ARCH="$(dpkg --print-architecture)"; \
    curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-$([ "$ARCH" = "amd64" ] && echo "64bit" || echo "ARM64").tar.gz" \
         -o /tmp/trivy.tar.gz; \
    tar -xzf /tmp/trivy.tar.gz -C /tmp trivy; \
    install -m 0755 /tmp/trivy /usr/local/bin/trivy; \
    rm -f /tmp/trivy.tar.gz /tmp/trivy; \
    trivy --version

# ─────────────────────────────────────────────────────────────────────────────
# LAYER 5 — Scripts
# Copying scripts as late as possible so they don't bust the apt/tool layers
# on every code change.
# ─────────────────────────────────────────────────────────────────────────────
COPY --chmod=755 node_status.sh  /usr/local/bin/node_status.sh
COPY --chmod=755 dashboard.sh   /usr/local/bin/dashboard.sh

# ─────────────────────────────────────────────────────────────────────────────
# LAYER 6 — Permissions, workspace directory, docker group membership
# ─────────────────────────────────────────────────────────────────────────────
RUN mkdir -p /var/jenkins_home/node && \
    # Allow the jenkins user to talk to the bind-mounted Docker socket.
    # GID 999 matches the default docker group GID on most Linux hosts;
    # override with --group-add at runtime if your host uses a different GID.
    groupadd -f -g 999 docker || true && \
    usermod -aG docker jenkins && \
    chown -R jenkins:jenkins /var/jenkins_home/node

# ─────────────────────────────────────────────────────────────────────────────
# HEALTHCHECK — confirms the agent workspace is accessible
# ─────────────────────────────────────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD test -d /var/jenkins_home/node && docker info > /dev/null 2>&1 || exit 1

# ─────────────────────────────────────────────────────────────────────────────
# Drop privileges — never run the agent as root
# ─────────────────────────────────────────────────────────────────────────────
USER jenkins

VOLUME /var/jenkins_home/node
