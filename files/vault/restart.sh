#!/usr/bin/env bash

# restart and unseal Vault pods

# shellcheck disable=SC2207 # Prefer mapfile to split output
# shellcheck disable=SC2086 # Double quote prevent globbing

set -euo pipefail

NAMESPACE="vault"
  TIMEOUT="30s"

YELLOW='\x1B[1;33m'
 NOCLR='\x1B[0m'

pods=($(kubectl get pods -n $NAMESPACE \
  -l app.kubernetes.io/name=vault \
  -o jsonpath="{.items[*].metadata.name}"))

echo -e "\n${YELLOW}Restarting Vault pods...${NOCLR}\n"
for pod in "${pods[@]}"; do
  kubectl delete pod "$pod" -n $NAMESPACE --now --wait
done

for pod in "${pods[@]}"; do
  echo -e "\n${YELLOW}Waiting for pod $pod to be Ready...${NOCLR}"
  kubectl wait --for=condition=Ready pod/$pod \
    -n $NAMESPACE --timeout=$TIMEOUT &> /dev/null || {
    echo >&2 "Pod $pod failed to start after $TIMEOUT!"
    continue
  }
  echo -e "${YELLOW}Unsealing Vault node in pod $pod...${NOCLR}"
  kubectl get secrets vault-unseal-keys -n $NAMESPACE -o yaml | \
    yq '.data.unsealKeys | @base64d | from_yaml | .[] |
       "sleep .25s; echo; vault operator unseal \"\(.)\""' | \
    shuf -n 3 | \
    kubectl exec -i $pod -c vault -n $NAMESPACE -- sh -s
done
