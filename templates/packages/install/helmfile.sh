# https://github.com/helmfile/helmfile

# shellcheck disable=SC2148 # Tips depend on target shell

set -eo pipefail

REL="https://github.com/helmfile/helmfile/releases"
VER=$(curl -Is "$REL/latest" | sed -En 's/^location:.+\/tag\/v(.+)\r$/\1/p')

# check if latest version already installed
command -v helmfile &> /dev/null && {
  ver=$(helmfile version -o short 2> /dev/null)
  [ "$ver" == "$VER" ] && exit 9 # no change
}
ARCH=$(uname -m | sed -e 's/aarch64/arm64/' -e 's/x86_64/amd64/')
curl -fsSL "$REL/download/v${VER}/helmfile_${VER}_linux_${ARCH}.tar.gz" | \
  tar -xz -C /usr/local/bin --no-same-owner helmfile

# create wrapper script around `helm` for use
# by Helmfile to run custom commands prior to
# certain Helm actions
SCRIPT="/usr/local/bin/helm.sh"
cat <<'EOF' > $SCRIPT
#!/usr/bin/env bash
set -eo pipefail

get_chart_dir() {
  while [ "$1" ]; do
    [[ "$1" != -* && -d "$1" ]] && {
      echo "$1"
      return 0
    } || shift
  done
}

if [[ "$1" =~ ^(template|install|upgrade)$ ]]; then
  # run custom commands if hook
  # provided as environment var
  hook_env="HELM_${1^^}_HOOK"

  if [ "${!hook_env}" ]; then
    chart_dir=$(get_chart_dir "${@:2}")
    [ "$chart_dir" ] || {
      echo >&2 -e "Unable to determine chart directory from Helm command:\n$0 $*"
      exit 1
    }
    export CHART_DIR=$chart_dir
    # run in isolated subshell
    (eval "${!hook_env}") >&2
  fi
fi

exec helm "$@"
EOF
chmod +x $SCRIPT
