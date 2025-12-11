#!/usr/bin/env bash

# shellcheck disable=SC2164 # Use cd ... || exit if cd fails

if command -v security &> /dev/null; then
  # Vault password is stored in macOS "login" Keychain
  # under account ansible-vault and service "Home-K8s"
  exec security find-generic-password -a ansible-vault -s Home-K8s -w

elif [ -f /var/lib/awx/.vaultpass ]; then
  cd /var/lib/awx # no ./ansible.cfg here
  # pass encrypted using `awx_secret_key`
  cat <<'EOT' | exec ansible-vault decrypt --vault-password-file .vaultpass 2> /dev/null
$ANSIBLE_VAULT;1.1;AES256
64333836626236346165666237666462356562616462363164353063366634313966386136643631
3931643033353037396464393935333635633866356430340a383034643939316339386231363763
35346432656464363663363931613566396136313632386264323466666566636238623761353639
3333363236303730630a373137396439633466613063373637393236343633343135373138623631
64636161363963356364663438366139373534316231373366663331386335643165
EOT
else
  echo >&2 "No vault password available!"
  exit 1
fi
