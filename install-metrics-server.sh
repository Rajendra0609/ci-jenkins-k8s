#!/bin/bash

# Create and configure Metrics Server for Kubernetes

# Step 1: Install Metrics Server
echo "Installing Metrics Server..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Step 2: Wait for deployment to be created
sleep 10

# Step 3: Patch the deployment to allow insecure TLS (for self-signed certs)
echo "Patching Metrics Server to allow insecure TLS..."
kubectl patch deployment metrics-server -n kube-system   --type='json'   -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

# Step 4: Restart the deployment to apply changes
echo "Restarting Metrics Server deployment..."
kubectl rollout restart deployment metrics-server -n kube-system

# Step 5: Wait for rollout to complete
sleep 10

# Step 6: Verify metrics availability
echo "
Verifying Metrics Server installation..."
kubectl top nodes || echo "Metrics Server is not yet available. Please wait a few moments and try again."
kubectl top pods -n jenkins || echo "Metrics for Jenkins namespace are not yet available."

