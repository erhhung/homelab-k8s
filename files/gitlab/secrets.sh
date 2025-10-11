#!/usr/bin/env bash

# this script creates the ansible-vault-encrypted vars
# file "gitlab.secrets.yml" containing various secrets
# required for GitLab installation:
# https://docs.gitlab.com/charts/installation/secrets

# shellcheck disable=SC2164 # Use cd ... || exit if cd fails
# shellcheck disable=SC2155 # Declare and assign separately
# shellcheck disable=SC2091 # Remove $() to not exec output

set -eo pipefail
cd "$(dirname "$0")/../../"

export ANSIBLE_CONFIG=./ansible.cfg
OUT_FILE="vars/gitlab.secrets.yml"

LOWER_HEX="a-f0-9"
ALPHA_NUM="a-zA-Z0-9"

base64() {
  local b64bin=$(which base64)
  "$b64bin" -w0
}

# indent <nchars>
indent() {
  local nchars=$1 indent
  printf -v indent "%${nchars}s" ""
  awk '{print "'"$indent"'" $0}'
}

# random <nchars> [charset]
random() {
  local nchars=$1 charset="$2"
  if [ "$charset" ]; then
    head -c 4096 /dev/urandom | \
      LC_CTYPE=C tr -cd "$charset" | \
      head -c "$nchars"
  else
    head -c "$nchars" /dev/urandom
  fi
}

# genrsa <nbits> [indent=2]
genrsa() {
  echo "|"
  local nbits=$1 indent=${2:-2}
  openssl genrsa "$nbits" | indent "$indent"
}

# keygen <type> [prefix]
keygen() {
  local type=$1 prefix="$2"
  local name="${prefix}${type}_key"
  local file="/tmp/$name"

  ssh-keygen -t "$type" -f "$file" \
    -q -N "" -C gitlab.fourteeners.local

  cat <<EOT
$name: |
$(cat "$file" | indent 2)
$name.pub: |-
$(cat "$file.pub" | indent 2)
EOT
  rm -f "$file" "$file.pub"
}

# global.redis.auth.secret:
# https://docs.gitlab.com/charts/installation/secrets#redis-password
redis_password() {
  cat <<EOT
redis: $(random 64 $ALPHA_NUM)
EOT
}

# used for all GitLab webhooks to internal
# endpoints, such as CI Pipelines Exporter
webhook_token() {
  cat <<EOT
webhook: $(random 64 $ALPHA_NUM)
EOT
}

# global.shell.hostKeys.secret:
# https://docs.gitlab.com/charts/installation/secrets#ssh-host-keys
host_keys() {
  # GitLab Shell expects key names in
  # secret to have prefix "ssh_host_"
  keygen rsa     ssh_host_
  keygen ecdsa   ssh_host_
  keygen ed25519 ssh_host_
}

# global.shell.authToken.secret:
# https://docs.gitlab.com/charts/installation/secrets#gitlab-shell-secret
shell_token() {
  cat <<EOT
shell: $(random 64 $ALPHA_NUM)
EOT
}

# global.gitaly.authToken.secret:
# https://docs.gitlab.com/charts/installation/secrets#gitaly-secret
gitaly_token() {
  cat <<EOT
gitaly: $(random 64 $ALPHA_NUM)
EOT
}

# global.praefect.authToken.secret:
# https://docs.gitlab.com/charts/installation/secrets#praefect-secret
praefect_token() {
  cat <<EOT
praefect: $(random 64 $ALPHA_NUM)
EOT
}

# global.appConfig.suggested_reviewers.secret:
# https://docs.gitlab.com/charts/installation/secrets#gitlab-suggested-reviewers-secret
suggested_reviewers() {
  cat <<EOT
reviewers: $(random 32 $ALPHA_NUM | base64)
EOT
}

# global.workhorse.secret:
# https://docs.gitlab.com/charts/installation/secrets#gitlab-workhorse-secret
workhorse_secret() {
  cat <<EOT
workhorse: $(random 32 $ALPHA_NUM | base64)
EOT
}

# global.appConfig.gitlab_kas.secret:
# https://docs.gitlab.com/charts/installation/secrets#gitlab-kas-secret
# NOTE: Rails requires this secret to exist,
#       even if KAS subchart isn't deployed
kas_secret() {
  cat <<EOT
kas: $(random 32 $ALPHA_NUM | base64)
EOT
}

# gitlab.kas.privateApi.secret:
# https://docs.gitlab.com/charts/installation/secrets#gitlab-kas-api-secret
kas_api_secret() {
  cat <<EOT
api: $(random 32 $ALPHA_NUM | base64)
EOT
}

# gitlab.kas.websocketToken.secret:
# https://docs.gitlab.com/charts/installation/secrets#gitlab-kas-websocket-token-secret
kas_websocket_token() {
  cat <<EOT
websocket: $(random 72 | base64)
EOT
}

# global.railsSecrets.secret:
# https://docs.gitlab.com/charts/installation/secrets#gitlab-rails-secret
rails_secrets() {
  cat <<EOT
production:
  secret_key_base: $(random 128 $LOWER_HEX)
  otp_key_base: $(random 128 $LOWER_HEX)
  db_key_base: $(random 128 $LOWER_HEX)
  encrypted_settings_key_base: $(random 128 $LOWER_HEX)
  openid_connect_signing_key: $(genrsa 2048 4)
  active_record_encryption_primary_key:
    - $(random 32 $ALPHA_NUM)
  active_record_encryption_deterministic_key:
    - $(random 32 $ALPHA_NUM)
  active_record_encryption_key_derivation_salt: $(random 32 $ALPHA_NUM)
EOT
}

# global.pages.apiSecret.secret:
# https://docs.gitlab.com/charts/installation/secrets#gitlab-pages-secret
pages_api_secret() {
  cat <<EOT
api: $(random 32 $ALPHA_NUM | base64)
EOT
}

# global.pages.authSecret.secret:
# for signing JWT tokens if Pages access control is enabled
pages_auth_secret() {
  cat <<EOT
auth: $(random 64 $ALPHA_NUM | base64)
EOT
}

# global.oauth.gitlab-pages.secret:
# https://docs.gitlab.com/charts/installation/secrets#oauth-integration
pages_oauth() {
  cat <<EOT
appid: $(random 64 $ALPHA_NUM)
appsecret: $(random 64 $ALPHA_NUM)
EOT
}

# gitlab-runner.runners.secret:
# https://docs.gitlab.com/charts/installation/secrets#gitlab-runner-secret
# new runner registration workflow:
# https://docs.gitlab.com/ci/runners/new_creation_workflow#installing-gitlab-runner-with-helm-chart
# NOTE: key names are the expected
runner_token() {
  cat <<EOT
runner-registration-token: ""
runner-token: $(random 64 $ALPHA_NUM)
EOT
}

# global.zoekt.gateway.basicAuth.secretName:
# https://docs.gitlab.com/charts/installation/secrets#zoekt-basic-auth-password
# NOTE: key names are the expected
zoekt_basicauth() {
  cat <<EOT
gitlab_username: gitlab
gitlab_password: $(random 32 $ALPHA_NUM | base64)
EOT
}

# global.zoekt.indexer.internalApi.secretName
zoekt_api_secret() {
  cat <<EOT
api: $(random 32 $ALPHA_NUM | base64)
EOT
}

# global.registry.certificate.secret
registry_cert() (
  tmpdir=$(mktemp -d -p /tmp -t gitlab) || exit $?
  cd "$tmpdir" && trap 'rm -rf $tmpdir' EXIT

  openssl req -noenc -newkey rsa:2048 -keyout auth.key \
    -subj "/CN=gitlab-issuer" -out auth.csr 2> /dev/null
  openssl x509 -req -in auth.csr -days 3650 \
    -signkey auth.key -out auth.crt 2> /dev/null

  cat <<EOT
registry-auth.crt: |
$(cat auth.crt | indent 2)
registry-auth.key: |
$(cat auth.key | indent 2)
EOT
)

# global.registry.httpSecret.secret:
# https://docs.gitlab.com/charts/installation/secrets#registry-http-secret
registry_http_secret() {
  cat <<EOT
http: $(random 64 $ALPHA_NUM | base64)
EOT
}

# global.registry.notificationSecret.secret:
# https://docs.gitlab.com/charts/installation/secrets#registry-notification-secret
registry_notif_secret() {
  cat <<EOT
notification: '["$(random 32 $ALPHA_NUM)"]'
EOT
}

cat <<EOF > "$OUT_FILE"
# this var is a dictionary containing
# data for generic Kubernetes secrets.
# any key with a "gitlab-" prefix will
# be created directly as a Secret with
# that name; others will be referenced
# in one or more secret creation tasks
gitlab_secrets_data:
  $(redis_password)
  $(webhook_token)

  gitlab-host-keys:
$(host_keys | indent 4)

  gitlab-auth-tokens:
    $(   shell_token)
    $(  gitaly_token)
    $(praefect_token)

  gitlab-shared-secrets:
    $(suggested_reviewers)
    $(workhorse_secret)
    $(      kas_secret)

  gitlab-rails-secrets:
    secrets.yml: |
$(rails_secrets | indent 6)

  gitlab-pages-secrets:
    $(pages_api_secret)
    $(pages_auth_secret)
$(pages_oauth | indent 4)

  runner:
$(runner_token | indent 4)

  gitlab-kas-secrets:
    $(kas_api_secret)
    $(kas_websocket_token)

  gitlab-zoekt-secrets:
$(zoekt_basicauth | indent 4)
    $(zoekt_api_secret)

  gitlab-registry-secrets:
$(registry_cert | indent 4)
    $(registry_http_secret)
    $(registry_notif_secret)
EOF
echo

# vault will use the configured password file
ansible-vault encrypt "$OUT_FILE" 2> /dev/null
ansible-vault view    "$OUT_FILE"  | \
  pygmentize -l yaml -P style=native
