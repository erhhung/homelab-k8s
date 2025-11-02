# https://github.com/kubernetes-sigs/kustomize

# shellcheck disable=SC2148 # Tips depend on target shell

set -eo pipefail

REL="https://github.com/kubernetes-sigs/kustomize/releases/latest"
VER=$(curl -Is $REL | sed -En 's/^location:.+\/tag\/kustomize\/(.+)\r$/\1/p')

# check if latest version already installed
command -v kustomize &> /dev/null && {
  [ "$(kustomize version)" == "$VER" ] && exit 9 # no change
}
ARCH=$(uname -m | sed -e 's/aarch64/arm64/' -e 's/x86_64/amd64/')
curl -fsSL "$REL/download/kustomize_${VER}_linux_$ARCH.tar.gz" | \
  tar -xz -C /usr/local/bin --no-same-owner kustomize

# create our own wrapper script that sanitizes
# YAML files in and under the `kustomize build`
# directory (this is mainly to fix Kustomize's
# strict YAML parsing that chokes on duplicate
# keys, like labels, that Helm charts generate)
SCRIPT="/usr/local/bin/kustomize.sh"
cat <<'EOF' > $SCRIPT
#!/usr/bin/env bash
set -eo pipefail

sanitize() (
  while read file; do
    # this yq command does the following:
    # dedup keys with last-occurrence-wins
    # keep order of keys' first occurrence
    # preserve all docs with --- delimiter
    # preserve comments & trim whitespace

    # https://mikefarah.gitbook.io/yq/usage/tips-and-tricks#logic-without-if-elif-else
    # https://mikefarah.gitbook.io/yq/operators/multiply-merge#objects-and-arrays-merging

    yq -i --header-preprocess=false '{} as $temp
      | with(select(kind == "map"); $temp.init = {})
      | with(select(kind == "seq"); $temp.init = [])
      | . as $item ireduce ($temp.init; . *d $item)
      | "---\n\(to_yaml | trim)"' "$file"
  done < <(
    find "$1" \( -name '*.yaml' -o -name '*.yml' \)
  )
)
for arg in "$@"; do
  case "$arg" in
    build) build=1
           ;;
       -h|--help)
            help=1
           ;;
       -*) ;;
        *) [ ! "$build_dir" ] && [ "$build" ] \
           && [ -d "$arg" ] && build_dir="$arg"
           ;;
  esac
done

# sanitize only if actually building
[ "$build" ] && [ ! "$help" ] && \
  sanitize "${build_dir:-.}"

exec kustomize "$@"
EOF
chmod +x $SCRIPT
