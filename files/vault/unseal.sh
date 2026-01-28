#!/usr/bin/env bash

# unseal Vault pods, optionally restarting them first
#
# usage: unseal.sh [-r|--restart] [index1] [index2]...
#        indexN: zero-based pod index (0-2)
#        unseals all pods if none specified

# shellcheck disable=SC2181 # Check exit code with: if ! ...
# shellcheck disable=SC2207 # Prefer mapfile to split output
# shellcheck disable=SC2086 # Double quote prevent globbing
# shellcheck disable=SC2128 # Expanding array without index

set -o pipefail

  NAMESPACE="vault"
     SECRET="vault-unseal-keys"
   PKI_HOST="pki.fourteeners.local"
YUBIKEY_PIN="$YUBIKEY_UNLOCK_PIN" # set in .env
   ASC_FILE="/opt/vault-unseal/unseal-keys.asc"
    TIMEOUT="60s"
  THRESHOLD="3"

YELLOW='\x1B[1;33m'
 NOCLR='\x1B[0m'

unset RESTART PODS
while [ "$1" ]; do
  case  "$1" in
    -r|--restart)
      RESTART=true ;;
    [0-2])
      PODS+="$1" ;;
  esac
  shift
done

ERROR_FILE="/tmp/gpg-error.$$"
trap 'rm -f $ERROR_FILE' EXIT
# exit loop+script on Ctrl-C
trap "exit 130" INT

pods=($(kubectl get pods -n $NAMESPACE \
  -l app.kubernetes.io/name=vault \
  -o jsonpath="{.items[*].metadata.name}"))

if [ "$RESTART" ]; then
  echo -e "\n${YELLOW}Restarting Vault pods...${NOCLR}\n"
  for pod in "${pods[@]}"; do
    [ ! "$PODS" ] || [[ "$PODS" == *"${pod##*-}"* ]] || continue
    kubectl delete pod "$pod" -n $NAMESPACE --now --wait
  done
fi

ssh_pki() {
  ssh -i ~/.ssh/$USER -o StrictHostKeyChecking=no $PKI_HOST "$@"
}

unlock_yubikey() {
  local result
  result="$(ssh_pki ".gnupg/unlock-yubikey.sh" <<< $YUBIKEY_PIN 2>&1)"
  if [ $? -ne 0 ]; then
    echo >&2 -e "\n$result"
    exit 1
  fi
}

get_unseal_commands() {
  local keys result
  # first try getting unredacted keys from Secret
  keys=($(kubectl get secrets $SECRET -n $NAMESPACE -o yaml | \
    yq '.data.unsealKeys | @base64d | from_yaml | .[]'))

  if [[ "$keys" == redacted...* ]]; then
    # get keys from pki.fourteeners.local instead
    [ "$YUBIKEY_PIN" ] && unlock_yubikey

    result="$(ssh_pki "gpg --decrypt $ASC_FILE" 2> $ERROR_FILE)"
    if [ $? -eq 0 ]; then
      eval "keys=($result)"
    else
      echo >&2
      cat  >&2 $ERROR_FILE
      exit 1
    fi
  fi
  printf "sleep .25s; echo; vault operator unseal \"%s\"\n" "${keys[@]}"
}

for pod in "${pods[@]}"; do
  [ ! "$PODS" ] || [[ "$PODS" == *"${pod##*-}"* ]] || continue
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
