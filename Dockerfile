# ─────────────────────────────────────────────────────────────────────────────
# Jenkins Inbound Agent — Docker + Terraform + Node.js + Gitleaks + Security Tools
# Java 25 base (NO Java 21 anywhere)
# ─────────────────────────────────────────────────────────────────────────────
#
# CHANGELOG (this revision)
#
#   Added tools — matching what dashboard.sh checks for and previously
#   reported as missing: kubectl, helm, AWS CLI, HashiCorp Vault CLI,
#   ArgoCD CLI, Skaffold, Kustomize.
#
#   Size reductions:
#     1. Every GitHub-release CLI binary (gitleaks, trivy, kubectl, helm,
#        argocd, skaffold, kustomize) is now fetched and extracted in a
#        throwaway `builder` stage and copied into the final image with
#        COPY --from=builder. None of the builder's own layers — curl's
#        download cache, GitHub API JSON responses, leftover .tar.gz
#        files — ship in the final image, regardless of cleanup order.
#     2. `maven` is no longer installed via apt. Verified against this
#        Debian package family: maven depends on
#        `default-jre-headless | openjdk-{8,11,17,21}-jre-headless` — JDK
#        25 satisfies none of those alternatives, so apt would silently
#        install an entire second JRE just to satisfy that dependency,
#        directly contradicting "NO Java 21 anywhere" above and adding
#        200MB+ of dead weight. Maven now comes from the official binary
#        tarball instead, which runs on whatever JDK is already on
#        PATH/JAVA_HOME — no extra JRE, ever.
#     3. Repo-signing tooling (gnupg, lsb-release, apt-transport-https) is
#        installed AND purged (--auto-remove) inside the SAME RUN that
#        uses it. Docker layers are immutable once committed — removing a
#        package in a *later* RUN does not shrink the image, since the
#        earlier layer's bytes are still there underneath. The purge only
#        actually saves space if it happens in the same layer that did
#        the install, so the "add repos → install → purge repo tooling"
#        apt work is now one consolidated RUN block.
#     4. `ansible` (the full distribution, which bundles hundreds of
#        community collections) is replaced with `ansible-core` plus only
#        the collections this image's toolset implies (Docker, AWS,
#        Kubernetes). ansible-core is roughly an order of magnitude
#        smaller; add more collections with `ansible-galaxy collection
#        install` if your playbooks need others.
#     5. AWS CLI is installed via pip into the existing venv rather than
#        AWS's official installer, which requires `unzip` — this avoids
#        pulling in a whole extra package for one install step, and lets
#        pip's resolver reconcile its version against the boto3/botocore
#        pins already in that same command.
#
#   Note: `lynis` and `fontconfig` are left untouched — I couldn't
#   confirm from here whether any pipeline actually uses them. If they're
#   not in use, dropping them is easy additional savings; worth checking.
#
#   Also worth knowing: the ArgoCD CLI binary itself is unusually large
#   (~230MB — it bundles far more than a typical Go CLI). dashboard.sh's
#   ArgoCD check already degrades gracefully when the binary is absent
#   (prints a warning, doesn't fail), so it's genuinely optional — added
#   below since it was on the "missing tools" list, but if this agent
#   never actually runs `argocd` commands, removing that one stage step
#   + COPY line is the single biggest size win available here.
# ─────────────────────────────────────────────────────────────────────────────

ARG JENKINS_AGENT_BASE=latest-jdk25
ARG GITLEAKS_VERSION=8.24.3
ARG TERRAFORM_VERSION=1.11.4
ARG NODE_MAJOR=22
ARG MAVEN_VERSION=3.9.16

# ===============================================================================
# STAGE 1: builder — fetch & extract every GitHub/CDN-release CLI binary.
# Only the specific files named in the final stage's COPY --from=builder
# lines ever leave this stage; everything else here (curl, tar, jq, temp
# downloads) is discarded with the stage itself.
# ===============================================================================
FROM debian:bookworm-slim AS builder
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG GITLEAKS_VERSION
ARG MAVEN_VERSION

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates tar jq && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /out

# ---- gitleaks (pinned) ----
RUN curl -s "https://api.github.com/repos/gitleaks/gitleaks/releases/tags/v${GITLEAKS_VERSION}" \
      | grep "browser_download_url" | grep "linux_x64.tar.gz" | cut -d '"' -f 4 \
      | xargs curl -L -o gitleaks.tar.gz && \
    tar -xzf gitleaks.tar.gz gitleaks && \
    chmod +x gitleaks && rm gitleaks.tar.gz

# ---- trivy (latest) ----
RUN set -eux; \
    TRIVY_VERSION=$(curl -s https://api.github.com/repos/aquasecurity/trivy/releases/latest | jq -r '.tag_name' | tr -d 'v'); \
    curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" -o trivy.tar.gz; \
    tar -xzf trivy.tar.gz trivy; \
    chmod +x trivy; rm trivy.tar.gz

# ---- kubectl (latest stable — official dl.k8s.io method) ----
RUN set -eux; \
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt); \
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o kubectl; \
    chmod +x kubectl

# ---- helm (latest v3.x — pin to the v3 line since many charts still
#      assume v3 semantics; bump the filter to "v4." when you're ready) ----
RUN set -eux; \
    HELM_VERSION=$(curl -s "https://api.github.com/repos/helm/helm/releases?per_page=30" \
        | jq -r '[.[] | select(.prerelease==false) | select(.tag_name | startswith("v3."))][0].tag_name'); \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o helm.tar.gz; \
    tar -xzf helm.tar.gz --strip-components=1 linux-amd64/helm; \
    chmod +x helm; rm helm.tar.gz

# ---- ArgoCD CLI (latest) — see size note in the header CHANGELOG ----
RUN set -eux; \
    ARGOCD_VERSION=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | jq -r '.tag_name'); \
    curl -fsSL -o argocd "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64"; \
    chmod +x argocd

# ---- Skaffold (latest — Google's documented "always latest" alias) ----
RUN curl -fsSL -o skaffold "https://storage.googleapis.com/skaffold/releases/latest/skaffold-linux-amd64" && \
    chmod +x skaffold

# ---- Kustomize (latest — releases are tagged "kustomize/vX.Y.Z" in a
#      monorepo shared with other modules, so /releases/latest can't be
#      trusted; filter explicitly for that prefix instead) ----
RUN set -eux; \
    KUSTOMIZE_TAG=$(curl -s "https://api.github.com/repos/kubernetes-sigs/kustomize/releases?per_page=20" \
        | jq -r '[.[] | select(.prerelease==false) | select(.tag_name | startswith("kustomize/"))][0].tag_name'); \
    KUSTOMIZE_VERSION="${KUSTOMIZE_TAG#kustomize/}"; \
    curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/${KUSTOMIZE_TAG}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" -o kustomize.tar.gz; \
    tar -xzf kustomize.tar.gz kustomize; \
    chmod +x kustomize; rm kustomize.tar.gz

# ---- Apache Maven (pinned; official binary tarball — runs on whatever
#      JDK is already on PATH, so it can't pull in a second JRE the way
#      the apt package would) ----
RUN curl -fsSL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" -o maven.tar.gz && \
    tar -xzf maven.tar.gz && \
    rm maven.tar.gz

# ===============================================================================
# STAGE 2: final runtime image
# ===============================================================================
FROM jenkins/inbound-agent:${JENKINS_AGENT_BASE}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG GITLEAKS_VERSION
ARG TERRAFORM_VERSION
ARG NODE_MAJOR
ARG MAVEN_VERSION

LABEL maintainer="rajendra.daggubati1997@gmail.com" \
      version="2.492.3" \
      description="Jenkins inbound agent with Docker CLI, Terraform, Node.js, Gitleaks, Python 3 and security tooling" \
      org.opencontainers.image.source="https://github.com/Chowdary1997/Jenkins_jenkins_nodes_Dockerfle.git" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="Raja DevOps" \
      org.opencontainers.image.title="Jenkins Inbound Agent"

USER root

# ─────────────────────────────────────────────────────────────────────────────
# Core tools kept installed permanently (no repo-signing packages here —
# see the consolidated docker/terraform/vault/node block below for why).
# `maven` intentionally absent from this list — see CHANGELOG item 2.
# ─────────────────────────────────────────────────────────────────────────────
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        fontconfig \
        lynis \
        colorized-logs \
        git \
        jq && \
    rm -rf /var/lib/apt/lists/*

# ─────────────────────────────────────────────────────────────────────────────
# Docker + Terraform + Vault + Node.js
# gnupg/lsb-release/apt-transport-https are only needed to add these three
# repos and import their signing keys — installed AND purged in this same
# RUN so they never persist in a committed layer (see CHANGELOG item 3).
# ─────────────────────────────────────────────────────────────────────────────
RUN install -m 0755 -d /etc/apt/keyrings && \
    apt-get update && \
    apt-get install -y --no-install-recommends gnupg lsb-release apt-transport-https && \
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
        > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-buildx-plugin \
        docker-compose-plugin \
        "terraform=${TERRAFORM_VERSION}-1" \
        vault \
        nodejs && \
    apt-get purge -y --auto-remove gnupg lsb-release apt-transport-https && \
    rm -rf /var/lib/apt/lists/*

# ─────────────────────────────────────────────────────────────────────────────
# Python environment
# ansible-core + a targeted collection set replaces the full `ansible`
# distribution (see CHANGELOG item 4). AWS CLI added here via pip instead
# of the official installer, avoiding an `unzip` dependency (item 5).
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
        awscli \
        ansible-core \
        requests \
        PyYAML \
        jinja2 \
        hvac \
        kubernetes && \
    /opt/venv/bin/ansible-galaxy collection install \
        community.docker \
        amazon.aws \
        kubernetes.core && \
    rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/venv/bin:$PATH"

# ─────────────────────────────────────────────────────────────────────────────
# CLI binaries fetched in the builder stage
# ─────────────────────────────────────────────────────────────────────────────
COPY --from=builder --chmod=755 /out/gitleaks   /usr/local/bin/gitleaks
COPY --from=builder --chmod=755 /out/trivy      /usr/local/bin/trivy
COPY --from=builder --chmod=755 /out/kubectl    /usr/local/bin/kubectl
COPY --from=builder --chmod=755 /out/helm       /usr/local/bin/helm
COPY --from=builder --chmod=755 /out/argocd     /usr/local/bin/argocd
COPY --from=builder --chmod=755 /out/skaffold   /usr/local/bin/skaffold
COPY --from=builder --chmod=755 /out/kustomize  /usr/local/bin/kustomize
COPY --from=builder /out/apache-maven-${MAVEN_VERSION} /opt/maven
RUN ln -s /opt/maven/bin/mvn /usr/local/bin/mvn

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
