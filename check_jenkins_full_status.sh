#!/bin/bash

NAMESPACE=jenkins

echo "Checking resources in namespace: $NAMESPACE"

# Get all running pods with IP addresses
echo -e "
🔍 Pod IP Addresses:"
kubectl get pods -n $NAMESPACE -o wide

# Get all secrets
echo -e "
🔐 Secrets:"
kubectl get secrets -n $NAMESPACE

# Get all PersistentVolumes
echo -e "
📦 PersistentVolumes (PV):"
kubectl get pv

# Get all PersistentVolumeClaims
echo -e "
📄 PersistentVolumeClaims (PVC):"
kubectl get pvc -n $NAMESPACE

# Get all resources in the namespace
echo -e "
📊 All Resources in Namespace:"
kubectl get all -n $NAMESPACE

# Get resource usage (requires metrics-server)
echo -e "
📈 Resource Usage (CPU/Memory):"
kubectl top pods -n $NAMESPACE

# Get logs from Jenkins pod
echo -e "
📝 Jenkins Pod Logs:"
JENKINS_POD=$(kubectl get pods -n $NAMESPACE -l app=jenkins -o jsonpath='{.items[0].metadata.name}')
kubectl logs $JENKINS_POD -n $NAMESPACE --tail=100

