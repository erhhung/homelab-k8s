#!/usr/bin/env bash

# shellcheck disable=SC2164 # Use cd ... || exit if cd fails
# shellcheck disable=SC2181 # Check exit code with: if ! ...

cd "$(dirname "$0")"
SCD_FILE="$(pwd)/$(basename "$0" .sh).scd"

if (($#)); then
  CARD_PIN="$1"
elif [ ! -t 0 ]; then
  CARD_PIN="$(cat -)"
else
  CARD_PIN="$YUBIKEY_PIN"
fi
[ "$CARD_PIN" ] || {
  echo >&2 "No PIN provided!"
  exit 1
}

APP_ID="$(gpg --card-status | sed -En 's/^App.+ID.+:\s+(\w+)$/\1/p')"
export CARD_PIN APP_ID

result="$(gpg-connect-agent --quiet --subst \
  --run "$SCD_FILE" /bye < /dev/null 2>&1)"

if [ $? -ne 0 ] || grep -q '^ERR ' <<< "$result"; then
  printf >&2 '%s\n' "$result"
  exit 1
fi
