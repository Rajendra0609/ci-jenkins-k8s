# ci-jenkins-k8s
Production-ready Jenkins LTS image for Kubernetes with preinstalled enterprise plugins and security hardening.



export DOCKER_CONFIG="/root/.docker/config.json"
export DESTINATION="docker.io/daggu1997/jenkins-docker-k8s:v1.0.1"

./build-kaniko.sh

./build-kaniko.sh \
  --docker-config "/root/.docker/config.json" \
  --destination "docker.io/daggu1997/jenkins-docker-k8s:v1.0.1" \
  --cache-repo "docker.io/daggu1997/cache" \
  --verbosity info

./build-kaniko.sh   --docker-config "$HOME/.docker/config.json"   --destination "docker.io/daggu1997/jenkins-docker-k8s:v1.0.3"   --cache-repo "docker.io/daggu1997/cache"   --verbosity info
