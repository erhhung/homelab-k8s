#!/usr/bin/env bash

# this script generates new GnuPG signing key
# for Gitea's internal commit/action signing

set -euo pipefail

KEY_NAME="Gitea Server"
KEY_EMAIL="gitea@fourteeners.local"
KEY_COMMENT="Gitea internal Git signing key"

 GNUPGHOME="/tmp/gitea-gpg/home"
EXPORT_DIR="/tmp/gitea-gpg/export"

mkdir -p  "$GNUPGHOME" "$EXPORT_DIR"
chmod 700 "$GNUPGHOME" "$EXPORT_DIR"

# https://www.gnupg.org/documentation/manuals/gnupg/Unattended-GPG-key-generation.html
cat <<EOF > "$EXPORT_DIR/gitea-gpg-key.batch"
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Name-Real: $KEY_NAME
Name-Email: $KEY_EMAIL
Name-Comment: $KEY_COMMENT
Expire-Date: 10y
%commit
EOF

gpg --homedir "$GNUPGHOME" --batch \
    --generate-key "$EXPORT_DIR/gitea-gpg-key.batch"

FPR="$(
  gpg --homedir "$GNUPGHOME" --batch --with-colons \
      --list-secret-keys "$KEY_EMAIL" | \
    awk -F: '/^fpr:/ { print $10; exit }'
)"
echo "$FPR" > "$EXPORT_DIR/fingerprint.txt"

gpg --homedir "$GNUPGHOME" --armor \
    --export "$FPR" \
  > "$EXPORT_DIR/gitea-public.asc"

gpg --homedir "$GNUPGHOME" --armor \
    --export-secret-keys "$FPR" \
  > "$EXPORT_DIR/gitea-private.asc"

chmod 600 "$EXPORT_DIR/gitea-private.asc"

echo -e "\nGenerated Gitea signing key:"
echo "  Fingerprint: $FPR"
echo "  Public  key: $EXPORT_DIR/gitea-public.asc"
echo "  Private key: $EXPORT_DIR/gitea-private.asc"
