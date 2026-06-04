#!/bin/bash

# remove_jenkins.sh
# -----------------
# Safely (and forcefully when necessary) remove Jenkins resources from the
# cluster. This script attempts graceful deletion first, then forces removal of
# stuck pods, removes blocking finalizers from PVCs/PVs and the namespace, and
# finally deletes PVs that were bound to PVCs in the `jenkins` namespace.
#
# Warning: Forcibly removing finalizers or force-deleting pods may cause data
# loss for stateful workloads. Use with care.

NAMESPACE=jenkins

# Banner (opt-out via SKIP_BANNER=1)
if [ -z "$SKIP_BANNER" ]; then
	NC="\e[0m"
	BOLD="\e[1m"
	GREEN="\e[32m"
	YELLOW="\e[33m"
	RED="\e[31m"
	CYAN="\e[36m"

	TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	HOSTNAME=$(hostname 2>/dev/null || echo "unknown-host")

	echo -e "${CYAN}${BOLD}================== Jenkins removal: START ==================${NC}"
	echo -e "${BOLD}Time:${NC} ${TIMESTAMP}    ${BOLD}Host:${NC} ${HOSTNAME}    ${BOLD}Namespace:${NC} ${NAMESPACE}"
	echo -e "${YELLOW}Note:${NC} This script will attempt to force-delete stuck resources and
	remove finalizers when necessary. Use SKIP_BANNER=1 to skip this header."
	echo
fi

if ! command -v kubectl >/dev/null 2>&1; then
	echo "kubectl not found in PATH. Aborting." >&2
	exit 1
fi

echo "Starting deletion of resources in namespace: $NAMESPACE"

# Try graceful deletion first (non-blocking)
kubectl delete all --all -n "$NAMESPACE" --wait=false || true
kubectl delete pvc --all -n "$NAMESPACE" --wait=false || true
kubectl delete secret --all -n "$NAMESPACE" --wait=false || true
kubectl delete configmap --all -n "$NAMESPACE" --wait=false || true

echo "Initiated graceful deletes. Waiting briefly to observe stuck resources..."
sleep 5

# Force-delete pods that are stuck in Terminating or in Unknown state
echo "Force-deleting pods stuck in Terminating or Unknown (if any)"
stuck_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '/Terminating|Unknown/ {print $1}')
if [ -n "$stuck_pods" ]; then
	for p in $stuck_pods; do
		echo "Force deleting pod: $p"
		kubectl delete pod "$p" -n "$NAMESPACE" --grace-period=0 --force || true
	done
fi

# Retry loop: wait up to ~30s for pods to disappear, otherwise attempt force delete again
for i in {1..6}; do
	remaining=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
	if [ "$remaining" = "0" ]; then
		echo "No pods remain in namespace $NAMESPACE"
		break
	fi
	echo "Pods remaining: $remaining — re-checking (attempt $i/6)"
	sleep 5
	stuck_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '/Terminating|Unknown/ {print $1}')
	for p in $stuck_pods; do
		echo "Force deleting pod: $p"
		kubectl delete pod "$p" -n "$NAMESPACE" --grace-period=0 --force || true
	done
done

# Handle PVCs that are stuck (remove finalizers) and delete bound PVs
echo "Checking PVCs in namespace $NAMESPACE to remove blocking finalizers and delete bound PVs"
pvcs=$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.volumeName}{"\n"}{end}' 2>/dev/null || true)
if [ -n "$pvcs" ]; then
	echo "$pvcs" | while IFS=: read -r pvc pv; do
		if [ -z "$pvc" ]; then
			continue
		fi
		echo "Processing PVC: $pvc  (bound PV: ${pv:-none})"

		# Attempt to remove PVC finalizers (non-destructive attempt)
		kubectl patch pvc "$pvc" -n "$NAMESPACE" -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1 || true

		# If a PV is bound, try to delete it (and clear its finalizers if needed)
		if [ -n "$pv" ] && [ "$pv" != "<none>" ]; then
			echo "Attempting to delete bound PV: $pv"
			kubectl delete pv "$pv" --wait=false >/dev/null 2>&1 || true
			# Remove finalizers on PV if it's stuck
			kubectl patch pv "$pv" -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1 || true
		fi
	done
fi

# Final attempt to delete any remaining PVCs (force removal of finalizers first)
echo "Force cleaning any remaining PVCs in $NAMESPACE"
for pvc in $(kubectl get pvc -n "$NAMESPACE" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | awk '{print $1}'); do
	echo "Removing finalizers for PVC: $pvc"
	kubectl patch pvc "$pvc" -n "$NAMESPACE" -p '[{"op":"remove","path":"/metadata/finalizers"}]' --type=json >/dev/null 2>&1 || kubectl patch pvc "$pvc" -n "$NAMESPACE" -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1 || true
	echo "Deleting PVC: $pvc"
	kubectl delete pvc "$pvc" -n "$NAMESPACE" --wait=false || true
done

# Remove finalizers from the namespace (force delete namespace if stuck)
echo "Attempting to delete namespace: $NAMESPACE"
kubectl delete namespace "$NAMESPACE" --wait=false >/dev/null 2>&1 || true

echo "If namespace is stuck terminating, removing finalizers to force deletion"
kubectl patch namespace "$NAMESPACE" -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1 || kubectl patch namespace "$NAMESPACE" --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true

kubectl patch pv jenkins-pv --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'
kubectl get pv
echo "Cleanup complete — verify with: kubectl get namespace $NAMESPACE; kubectl get pv | grep jenkins || true"


