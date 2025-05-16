#!/usr/bin/env bash

# this script downloads the latest Grafana OpenAPI
# specs and patches in our Grafana server endpoint

# USAGE: ./openapi.sh | pbcopy
#  THEN:
#   1. open browser: https://editor-next.swagger.io/
#   2. paste in patched OpenAPI specs from clipboard
#      and click the Authorize button for basic auth

GRAFANA_OPENAPI_URL="https://raw.githubusercontent.com/grafana/grafana/refs/heads/main/public/openapi3.json"
 GRAFANA_SERVER_URL="https://grafana.fourteeners.local/api"

LTBLUE=$'\x1B[1;34m'
YELLOW=$'\x1B[1;33m'
 WHITE=$'\x1B[1;37m'
  CYAN=$'\x1B[0;36m'
 NOCLR=$'\x1B[0m'

curl -sfL "$GRAFANA_OPENAPI_URL" |   \
  jq --arg url "$GRAFANA_SERVER_URL" \
      '.servers = [{url: $url}]' |   \
  yq -pj -oy

echo >&2
cat <<EOT >&2
${LTBLUE}USAGE: ${YELLOW}$0 | pbcopy${NOCLR}

   ${WHITE}Paste the copied OpenAPI specs into the Swagger Editor
   at ${CYAN}https://editor-next.swagger.io/${WHITE} and click Authorize
   to authenticate by username and password.${NOCLR}
EOT
