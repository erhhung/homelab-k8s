#!/usr/bin/env bash

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

 KUBECTL_CMD="kubectl --context homelab -n litellm"
APP_SELECTOR='app.kubernetes.io/name=litellm'

AUTH_SECRET=litellm-chatgpt-auth
REMOTE_FILE=/data/chatgpt/auth.json
 LOCAL_FILE=files/litellm/chatgpt/auth.json

YELLOW='\x1B[1;33m'
LTCYAN='\x1B[1;36m'
  PINK='\x1B[1;35m'
 NOCLR='\x1B[0m'

color_yellow() { echo -e "${YELLOW}$*${NOCLR}"; }
color_ltcyan() { echo -e "${LTCYAN}$*${NOCLR}"; }
color_pink()   { echo -e   "${PINK}$*${NOCLR}"; }

# ensure kubectl works & auth Secret exists
$KUBECTL_CMD get secret $AUTH_SECRET -o name > /dev/null

# update auth Secret with empty JSON object
color_ltcyan '\n1. Edit Secret `litellm-chatgpt-auth` and make JSON object empty'
$KUBECTL_CMD patch secret $AUTH_SECRET --type merge \
  -p '{"data":{"auth.json":"e30K"}}'

# delete "chatgpt/auth.json" from container
color_ltcyan '\n2. Shell into LiteLLM container and `rm /data/chatgpt/auth.json`'
pod_name="$($KUBECTL_CMD get pod -l "$APP_SELECTOR" -o name)"
$KUBECTL_CMD exec $pod_name -c litellm -- rm -vf $REMOTE_FILE

# restart LiteLLM pod and monitor log output
color_ltcyan '\n3. Restart LiteLLM pod and watch container logs for instructions'
restart_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
$KUBECTL_CMD rollout restart deployment -l "$APP_SELECTOR"

# wait for new pod main container to run
echo "waiting for the new pod to run..."
until pod_name=$(
  $KUBECTL_CMD get pod -l "$APP_SELECTOR" -o json | \
    jq -r --arg ts "$restart_ts" '.items[]  |
        select(.status.containerStatuses[]? |
          select(.name == "litellm" and
                 .state.running.startedAt > $ts)
        ) |
        .metadata.name'
); [ "$pod_name" ]; do
  sleep 1
done

until auth_prompt=$(
  $KUBECTL_CMD logs $pod_name -c litellm --tail=10 | \
    sed -n '/^Sign in with ChatGPT/,/^Device codes/{ /^Device codes/!p; }'
); [ "$auth_prompt" ]; do
  sleep 1
done
color_yellow "\n$auth_prompt"

# pod should become ready after user sign-in
color_pink '\nwaiting for user to sign-in...'
$KUBECTL_CMD wait --for=condition=Ready pod $pod_name --timeout=5m

color_ltcyan \
  '\n4. Shell into container again and `cat /data/chatgpt/auth.json`' \
  '\n   to copy the entire JSON content to replace Ansible-encrypted' \
  '\n   file "files/litellm/chatgpt/auth.json" and update the Secret'
auth_json="$($KUBECTL_CMD exec $pod_name -c litellm -- cat $REMOTE_FILE)"

# update auth Secret with "auth.json" data
$KUBECTL_CMD patch secret $AUTH_SECRET --type merge -p "$(cat <<EOT
{ "data": { "auth.json": "$(printf '%s' "$auth_json" | base64 -w0)" } }
EOT
)"
# update Ansible-encrypted "auth.json" file
printf '%s' "$auth_json" | ansible-vault encrypt - --output $LOCAL_FILE
