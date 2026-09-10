# Use official Jenkins LTS
FROM jenkins/jenkins:2.568.1
LABEL maintainer="rajendra.daggubati1997@gmail.com" \
      version="2.555.3-k8s" \
      description="Production-ready Jenkins for Kubernetes" \
      org.opencontainers.image.source="https://github.com/Chowdary1997/Jenkins_jenkins_nodes_Dockerfle.git" \
      org.opencontainers.image.licenses="MIT"

USER root

# Install minimal required tools (NO Docker inside container)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        git \
        maven \
        gnupg && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install recommended production plugins
COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Security hardening
RUN mkdir -p /var/jenkins_home && \
    chown -R jenkins:jenkins /var/jenkins_home
    
# Disable setup wizard (production auto setup)
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"

# Security hardening
RUN mkdir -p /var/jenkins_home && \
    chown -R jenkins:jenkins /var/jenkins_home

VOLUME /var/jenkins_home

EXPOSE 8080 50000

USER jenkins

ENTRYPOINT ["/usr/local/bin/jenkins.sh"]
