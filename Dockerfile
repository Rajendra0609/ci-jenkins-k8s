# ─────────────────────────────────────────────────────────────────────────────
# Jenkins Inbound Agent — Docker + Terraform + Node.js + Gitleaks + Security Tools
# Java 25 base (NO Java 21 anywhere)
# ─────────────────────────────────────────────────────────────────────────────

ARG JENKINS_AGENT_BASE=latest-jdk25
ARG GITLEAKS_VERSION=8.24.3
ARG TERRAFORM_VERSION=1.11.4
ARG NODE_MAJOR=22

FROM jenkins/inbound-agent:${JENKINS_AGENT_BASE}

ARG GITLEAKS_VERSION
ARG TERRAFORM_VERSION
ARG NODE_MAJOR

LABEL maintainer="rajendra.daggubati1997@gmail.com" \
      version="2.492.3" \
      description="Jenkins inbound agent with Docker CLI, Terraform, Node.js, Gitleaks, Python 3 and security tooling" \
      org.opencontainers.image.source="https://github.com/Chowdary1997/Jenkins_jenkins_nodes_Dockerfle.git" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="Raja DevOps" \
      org.opencontainers.image.title="Jenkins Inbound Agent"

USER root

# ─────────────────────────────────────────────────────────────────────────────
# Core tools (NO Java install — base image already has Java 25)
# Removed: wget, unzip — nothing in this Dockerfile uses either (all downloads
# use curl; gitleaks/trivy are extracted from .tar.gz, not .zip)
# ─────────────────────────────────────────────────────────────────────────────
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        fontconfig \
        maven \
        lynis \
        colorized-logs \
        git \
        jq && \
    rm -rf /var/lib/apt/lists/*

# ─────────────────────────────────────────────────────────────────────────────
# Docker + Terraform + Node.js repositories
# ─────────────────────────────────────────────────────────────────────────────
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
        > /etc/apt/sources.list.d/docker.list && \
    curl -fsSL https://apt.releases.hashicorp.com/gpg | \
        gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/hashicorp.list && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
        gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list

# ─────────────────────────────────────────────────────────────────────────────
# Docker CLI + Terraform + Node.js
# ─────────────────────────────────────────────────────────────────────────────
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-buildx-plugin \
        docker-compose-plugin \
        terraform=${TERRAFORM_VERSION}-1 \
        nodejs && \
    rm -rf /var/lib/apt/lists/*

# ─────────────────────────────────────────────────────────────────────────────
# Python environment
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
    rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/venv/bin:$PATH"

# ─────────────────────────────────────────────────────────────────────────────
# Gitleaks (pinned version support)
# ─────────────────────────────────────────────────────────────────────────────
RUN set -eux; \
    curl -s https://api.github.com/repos/gitleaks/gitleaks/releases/tags/v${GITLEAKS_VERSION} \
    | grep "browser_download_url" \
    | grep "linux_x64.tar.gz" \
    | cut -d '"' -f 4 \
    | xargs curl -L -o gitleaks.tar.gz; \
    tar -xzf gitleaks.tar.gz; \
    chmod +x gitleaks; \
    mv gitleaks /usr/local/bin/gitleaks; \
    rm -f gitleaks.tar.gz

# ─────────────────────────────────────────────────────────────────────────────
# Trivy scanner
# ─────────────────────────────────────────────────────────────────────────────
RUN set -eux; \
    TRIVY_VERSION=$(curl -s https://api.github.com/repos/aquasecurity/trivy/releases/latest \
        | jq -r '.tag_name' | tr -d 'v'); \
    ARCH="$(dpkg --print-architecture)"; \
    curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
        -o /tmp/trivy.tar.gz; \
    tar -xzf /tmp/trivy.tar.gz -C /tmp trivy; \
    install -m 0755 /tmp/trivy /usr/local/bin/trivy; \
    rm -f /tmp/trivy.tar.gz /tmp/trivy

# ─────────────────────────────────────────────────────────────────────────────
# Scripts
# ─────────────────────────────────────────────────────────────────────────────
COPY --chmod=755 node_status.sh /usr/local/bin/node_status.sh
COPY --chmod=755 dashboard.sh /usr/local/bin/dashboard.sh

# ─────────────────────────────────────────────────────────────────────────────
# Permissions
# ─────────────────────────────────────────────────────────────────────────────
RUN mkdir -p /var/jenkins_home/node && \
    groupadd -f -g 999 docker || true && \
    usermod -aG docker jenkins && \
    chown -R jenkins:jenkins /var/jenkins_home/node

# ─────────────────────────────────────────────────────────────────────────────
# Healthcheck
# ─────────────────────────────────────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD docker info > /dev/null 2>&1

# ─────────────────────────────────────────────────────────────────────────────
# Runtime user
# ─────────────────────────────────────────────────────────────────────────────
USER jenkins

VOLUME /var/jenkins_home/node
