#!/usr/bin/env bash

# restart and unseal Vault pods

# shellcheck disable=SC2207 # Prefer mapfile to split output
# shellcheck disable=SC2086 # Double quote prevent globbing
# shellcheck disable=SC2128 # Expanding array without index

set -euo pipefail

NAMESPACE="vault"
   SECRET="vault-unseal-keys"
 PKI_HOST="pki.fourteeners.local"
 ASC_FILE="/opt/vault-unseal/unseal-keys.asc"
  TIMEOUT="60s"
THRESHOLD="3"

YELLOW='\x1B[1;33m'
 NOCLR='\x1B[0m'

pods=($(kubectl get pods -n $NAMESPACE \
  -l app.kubernetes.io/name=vault \
  -o jsonpath="{.items[*].metadata.name}"))

echo -e "\n${YELLOW}Restarting Vault pods...${NOCLR}\n"
for pod in "${pods[@]}"; do
  kubectl delete pod "$pod" -n $NAMESPACE --now --wait
done

get_unseal_commands() {
  # first try getting unredacted keys from Secret
  keys=($(kubectl get secrets $SECRET -n $NAMESPACE -o yaml | \
    yq '.data.unsealKeys | @base64d | from_yaml | .[]'))

  if [[ "$keys" == redacted...* ]]; then
    # get keys from pki.fourteeners.local instead
    keys=($(ssh -i ~/.ssh/$USER -o StrictHostKeyChecking=no $PKI_HOST \
      "gpg --decrypt $ASC_FILE 2>/dev/null"))
  fi
  printf "sleep .25s; echo; vault operator unseal \"%s\"\n" "${keys[@]}"
}

for pod in "${pods[@]}"; do
  echo -e "\n${YELLOW}Waiting for pod $pod to be Ready...${NOCLR}"
  kubectl wait --for=condition=Ready pod/$pod \
    -n $NAMESPACE --timeout=$TIMEOUT &> /dev/null || {
    echo >&2 "Pod $pod failed to start after $TIMEOUT!"
    continue
  }
  echo -e "${YELLOW}Unsealing Vault node at pod $pod...${NOCLR}"
  get_unseal_commands | shuf -n $THRESHOLD | \
    kubectl exec -i $pod -c vault -n $NAMESPACE -- sh -s
done
