# https://github.com/helmfile/helmfile

# shellcheck disable=SC2148 # Tips depend on target shell

set -eo pipefail

REL="https://github.com/helmfile/helmfile/releases"
VER=$(curl -ILs "$REL/latest" | sed -En 's/^location:.+\/tag\/v(.+)\r$/\1/p')

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

get_operation() {
  [[ "$1" =~ ^(template|install|upgrade)$ ]] && echo "$1"
}
get_chart_dir() {
  while [ "$1" ]; do
    [[ "$1" != -* && -d "$1" ]] && {
      echo "$1"
      return 0
    } || shift
  done
}
      args=()
extra_args=()

# Helmfile invokes this script with --kubeconfig
# /path/to/config.yaml as first 2 args, followed
# by the operation
op=$(get_operation "$3" || \
     get_operation "$1" || true)

if [ "$op" ]; then
  # run custom commands if hook
  # provided as environment var
  hook_env="HELM_${op^^}_HOOK"

  if [ "${!hook_env}" ]; then
    chart_dir=$(get_chart_dir "$@")
    [ "$chart_dir" ] || {
      echo >&2 -e "Unable to determine chart directory from Helm command:\n$0 $*"
      exit 1
    }
    export CHART_DIR=$chart_dir
    # run in isolated subshell
    (eval "${!hook_env}") >&2
  fi

  args_env="HELM_${op^^}_ARGS"
  if [ "${!args_env}" ]; then
    extra_args+=(${!args_env})
  fi
fi

while [ "$1" ]; do
  arg="$1"; shift
  case "$arg" in
    --atomic)
      # Helm v4 deprecated `--atomic` in
      # favor of `--rollback-on-failure`
      arg=--rollback-on-failure
      ;;
  esac
  args+=("$arg")
done

exec helm "${args[@]}" "${extra_args[@]}"
EOF
chmod +x $SCRIPT
