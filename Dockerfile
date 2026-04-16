FROM jenkins/inbound-agent:latest

LABEL maintainer="rajendra.daggubati1997@gmail.com" \
      version="2.492.3" \
      description="Jenkins with Docker support" \
      org.opencontainers.image.source="https://github.com/Chowdary1997/Jenkins_jenkins_nodes_Dockerfle.git" \
      org.opencontainers.image.licenses="MIT"

# Install Docker CLI and dependencies
USER root

# Environment variables (defaults can be overridden at runtime)
ENV JENKINS_URL="" \
    JENKINS_SECRET="" \
    JENKINS_AGENT_NAME="docker" \
    JENKINS_WEB_SOCKET="true" \
    JENKINS_AGENT_WORKDIR="/var/jenkins_home/node"

RUN apt-get update && \
    apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    wget \
    maven \
    gnupg \
    lsb-release \
    lynis \
    colorized-logs \
    fontconfig \
    openjdk-21-jre && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo ${VERSION_CODENAME}) stable" > /etc/apt/sources.list.d/docker.list' && \
    apt-get update && \
    apt-get install -y docker-ce docker-ce-cli containerd.io && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install Gitleaks (latest release)
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

RUN wget -O- https://apt.releases.hashicorp.com/gpg | \
    gpg --dearmor | \
    tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null

RUN gpg --no-default-keyring \
    --keyring /usr/share/keyrings/hashicorp-archive-keyring.gpg \
    --fingerprint

RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list

RUN apt update
RUN apt-get install -y terraform

# Copy the script into the image
COPY node_status.sh /usr/local/bin/node_status.sh

# Make it executable
RUN chmod +x /usr/local/bin/node_status.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
# Optional: Create volume
VOLUME /var/jenkins_home/node
ENTRYPOINT ["/entrypoint.sh"]
