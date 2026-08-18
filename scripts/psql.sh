#!/usr/bin/env bash

# start an interactive `psql` prompt on the primary PostgreSQL
# pod if no SQL statements or psql meta-commands are provided
# via stdin; otherwise, executes commands from stdin (one per
# line) and exit

# shellcheck disable=SC2181 # Check exit code with: if ! ...
# shellcheck disable=SC2207 # Prefer mapfile to split output
# shellcheck disable=SC2086 # Double quote prevent globbing

set -o pipefail

kubectl="kubectl --context homelab --namespace postgresql"

SCRIPT="$(cat <<'EOF'
psql="psql -U postgres"

is_primary() {
  [ "$($psql -tAc 'SELECT pg_is_in_recovery()')" != t ]
}

start_psql() {
  [ -p /dev/stdin ] && stdin="$(cat)"

  if [ "$stdin" ]; then
    while read -r line; do
      cmds+=(-c "$line")
    done <<< "$stdin"

    $psql "${cmds[@]}" 2>&1
  else
    PSQL_HISTORY=/dev/null $psql -q
  fi
}
EOF
)"

pods=($($kubectl get pods \
  -l app.kubernetes.io/component=postgresql \
  -o jsonpath="{.items[*].metadata.name}"))
args=(-i); [ -t 0 ] && [ -t 1 ] && args+=(-t)

for pod in "${pods[@]}"; do
  $kubectl exec "$pod" -c postgresql "${args[@]}" -- bash -c \
    "$SCRIPT; is_primary || exit 9; start_psql" 2> /dev/null
  rc=$?; [ $rc -ne 9 ] && exit $rc
done
