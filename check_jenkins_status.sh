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

