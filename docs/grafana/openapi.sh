#!/usr/bin/env bash

# this script downloads the latest Grafana OpenAPI
# specs and patches in our Grafana server endpoint

# USAGE: ./openapi.sh | pbcopy
#  THEN:
#   1. open browser: https://editor-next.swagger.io/
#   2. paste in patched OpenAPI specs from clipboard
#      and click the Authorize button for basic auth

GRAFANA_OPENAPI_URL="https://raw.githubusercontent.com/grafana/grafana/refs/heads/main/public/openapi3.json"
 GRAFANA_SERVER_URL="https://grafana.fourteeners.local"

curl -sfL "$GRAFANA_OPENAPI_URL" |   \
  jq --arg url "$GRAFANA_SERVER_URL" \
      '.servers = [{url: $url}]' |   \
  yq -pj -oy
