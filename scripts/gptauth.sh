#!/usr/bin/env bash

# shellcheck disable=SC2291 # Quote spaces prevent collapse
# shellcheck disable=SC2086 # Double quote prevent globbing
# shellcheck disable=SC2016 # Expr won't expand in '' quotes

# this script performs the following infrastructure and repository
# changes, waiting until the user completes the sign-in in browser
#
# 💡 ChatGPT Authentication OAuth Device Flow 💡
# ---------------------------------------------
# 1. edit Secret `litellm-chatgpt-auth` and make JSON object empty
# 2. shell into LiteLLM container and `rm /data/chatgpt/auth.json`
# 3. restart LiteLLM pod and watch container logs for instructions
#    Sign in with ChatGPT using device code:
#    1) Visit https://auth.openai.com/codex/device
#    2) Enter code: XXXX-YYYYY
# 4. shell into container again and `cat /data/chatgpt/auth.json`
#    to copy the entire JSON content to replace Ansible-encrypted
#    file "files/litellm/chatgpt/auth.json" and update the Secret

# run from project root
cd "$(dirname "$0")/.."
set -eo pipefail

kubectl="kubectl --context homelab -n litellm"
APP_SELECTOR='app.kubernetes.io/name=litellm'

AUTH_SECRET=litellm-chatgpt-auth
REMOTE_FILE=/data/chatgpt/auth.json
 LOCAL_FILE=files/litellm/chatgpt/auth.json

   RED='\x1B[0;31m'
YELLOW='\x1B[1;33m'
LTCYAN='\x1B[1;36m'
  PINK='\x1B[1;35m'
 NOCLR='\x1B[0m'

color_red()    { echo -e    "${RED}$*${NOCLR}"; }
color_yellow() { echo -e "${YELLOW}$*${NOCLR}"; }
color_ltcyan() { echo -e "${LTCYAN}$*${NOCLR}"; }
color_pink()   { echo -e   "${PINK}$*${NOCLR}"; }

# ensure kubectl works & auth Secret exists
$kubectl get secret $AUTH_SECRET -o name > /dev/null

# update auth Secret with empty JSON object
color_ltcyan '\n1. Edit Secret `litellm-chatgpt-auth` and make JSON object empty'
$kubectl patch secret $AUTH_SECRET --type merge \
  -p '{"data":{"auth.json":"e30K"}}'

# delete "chatgpt/auth.json" from container
color_ltcyan '\n2. Shell into LiteLLM container and `rm /data/chatgpt/auth.json`'
pod_ref="$($kubectl get pod -l "$APP_SELECTOR" -o name)"
if $kubectl get $pod_ref -o json | jq -e '
     .status.containerStatuses[] | select(.name == "litellm")
                                 | .state.running' > /dev/null; then
  $kubectl exec $pod_ref -c litellm -- rm -vf $REMOTE_FILE
else
  color_red 'container is not running...skipping'
fi

# restart LiteLLM pod and monitor log output
color_ltcyan '\n3. Restart LiteLLM pod and watch container logs for instructions'
restart_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
$kubectl delete $pod_ref --now --wait

# wait for new pod init container to run
echo "waiting for the new pod to run..."
until pod_name=$(
  $kubectl get pod -l "$APP_SELECTOR" -o json | \
    jq -r --arg ts "$restart_ts" '.items[]    |
        select(.status.initContainerStatuses[]? |
          select(.name == "gpt-oauth" and
                 .state.running.startedAt > $ts)
        ) |
        .metadata.name'
); [ "$pod_name" ]; do
  sleep 1
done

until auth_prompt=$(
  $kubectl logs $pod_name -c gpt-oauth --tail=10 | \
    sed -n '/^Sign in with ChatGPT/,/^Device codes/{ /^Device codes/!p; }'
); [ "$auth_prompt" ]; do
  sleep 1
done
color_yellow "\n$auth_prompt"

# pod should become ready after user sign-in
color_pink '\nwaiting for user to sign-in and pod to become ready...'
$kubectl wait --for=condition=Ready pod $pod_name --timeout=5m

color_ltcyan \
  '\n4. Shell into container again and `cat /data/chatgpt/auth.json`' \
  '\n   to copy the entire JSON content to replace Ansible-encrypted' \
  '\n   file "files/litellm/chatgpt/auth.json" and update the Secret'
auth_json="$($kubectl exec $pod_name -c litellm -- cat $REMOTE_FILE)"

# update auth Secret with "auth.json" data
$kubectl patch secret $AUTH_SECRET --type merge -p "$(cat <<EOT
{ "data": { "auth.json": "$(printf '%s' "$auth_json" | base64 -w0)" } }
EOT
)"
# update Ansible-encrypted "auth.json" file
printf '%s' "$auth_json" | ansible-vault encrypt - --output $LOCAL_FILE 2>&1
