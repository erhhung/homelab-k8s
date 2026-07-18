#!/usr/bin/env bash

# shellcheck disable=SC2164 # Use cd ... || exit if cd fails

if command -v security &> /dev/null; then
  # Vault password is stored in macOS "login" Keychain
  # under account ansible-vault and service "Home-K8s"
  exec security find-generic-password -a ansible-vault -s Home-K8s -w

elif [ -f "$AGE_KEY_FILE" ]; then
  # Vault password is encrypted with `age`
  cat <<'EOT' | exec age -d -i "$AGE_KEY_FILE" 2> /dev/null
-----BEGIN AGE ENCRYPTED FILE-----
YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IFgyNTUxOSBGcnZmNG16TFBSMWhLVmV3
MUUvRmNOWjZSTjJ2d2s0MDA4ZUFuMU14Y0F3CnRheHUvSmtieFhTQWIwbzBBbGQ5
Z3krSFRGTXdVVm1nWmNPTzlNRUF6SlUKLS0tIGllaHRZblhNVW9NY09DSFVHem9T
Z05laUxVelBUMnJlNmdCQnlQVW5keXcKVzYg6S49fXFn38z8Jn0sUfLF6DKbTdr8
yG/2hGN0IXGtd23G9peGnRH+4mUX4PLACw==
-----END AGE ENCRYPTED FILE-----
EOT

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
