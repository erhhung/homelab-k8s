#!/usr/bin/env bash

[[ "$1" =~ ^(init|generate)$ ]] || {
  echo >&2 "Usage: $(basename "$0") <init|generate>"
  exit 1
}
echo >&2 "PHASE: $1 <=="

# Argo CD prefixes all environment variables defined
# in the Application spec with ARGOCD_ENV_, so remove
# the prefix so they're easier to use in helmfile.yaml
while IFS='=' read -r -d '' n v; do
  if [[ "$n" == ARGOCD_ENV_* ]]; then

    nv="${n##ARGOCD_ENV_}=$v"
    echo >&2 "$nv <=="
    eval "export $nv"
  fi
done < <(env -0)

echo >&2 "DIRECTORY: $(pwd) <=="
file="${HELMFILE_FILE:-helmfile.yaml}"

if [ ! -f "$file" ]; then
  # try finding .gotmpl variant
  if [ -f "$file.gotmpl" ]; then
     file+=".gotmpl"
  else
    echo >&2 "Helmfile file \"$file\" not found! <=="
    exit 1
  fi
fi

args=(
  --debug
  --file "$file"
  --environment "${HELMFILE_ENVIRONMENT:-default}"
)
[ "$HELMFILE_SELECTOR" ] && \
  args+=(--selector "$HELMFILE_SELECTOR")

case $1 in
  init)
    # clear existing Helm repos
    # to prevent name conflicts
    helm repo list -o json | jq -r '.[].name' | \
      xargs --max-args=1 --no-run-if-empty helm repo remove >&2

    helmfile repos "${args[@]}"
    helmfile deps  "${args[@]}"
    ;;
  generate)
    args=(
      helmfile template "${args[@]}"
      --include-crds
      --skip-deps
      --skip-tests
    )
    echo >&2 "EXECUTING: ${args[*]} <=="
    # capture helmfile stderr for debugging
    exec 3>&2 2> >(tee /tmp/helmfile.log >&3)
    exec "${args[@]}"
    ;;
esac
