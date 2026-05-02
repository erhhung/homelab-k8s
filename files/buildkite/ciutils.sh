# this script is automatically sourced
# by container-N when build pod starts

# shellcheck disable=SC2148 # Tips depend on target shell
# shellcheck disable=SC2155 # Declare and assign separately
# shellcheck disable=SC2086 # Double quote prevent globbing
# shellcheck disable=SC2046 # Quote to avoid word splitting
# shellcheck disable=SC2206 # Quote to avoid word splitting
# shellcheck disable=SC2015 # A && B || C isn't if-then-else
# shellcheck disable=SC2012 # find is better at non-alphanum
# shellcheck disable=SC2178 # Var was array but now string
# shellcheck disable=SC2179 # Use array+=("item") to append
# shellcheck disable=SC2128 # Expanding array without index

# show root path of current (super) project
git_root() {
  local root="$(git rev-parse --show-superproject-working-tree)"
  [ "$root" ] && echo "$root" || git rev-parse --show-toplevel
}

# <title>
section_start() {
  # https://buildkite.com/docs/pipelines/configure/managing-log-output
  local title="$*" blue='\e[1;34m' clear='\e[0m'
  echo -e "--- $blue===== $title =====$clear"
}

# [title]
section_end() {
  local title="$*" gray='\e[1;30m' clear='\e[0m'
  echo -e "+++ ${gray}${title:-\032}${clear}"
}

# trim leading and trailing newlines from stdin
trim_newlines() {
  sed -e :a -e '/./,$!d;/^\n*$/{$d;N;};/\n$/ba'
}

# run command in fake TTY (useful to force command to
# output color if it usually does so only with a TTY)
fake_tty() {
  script -qefc "stty rows 50 cols 5000; $(printf "%q " "$@")" /dev/null
}

# <lexer> [style]
colorize() {
  # lexer: yaml|json|bash...
  # style: see Pygments docs
  local lexer=$1 style=${2:-$PYGMENTSTYLE}
  pygmentize -l $lexer -O style=${style:-fruity}
}

# show color output but strip from log file
# [file]
tee_noclr() {
  [ "$1" ] && pee cat "sed 's/\x1b\[[0-9;]*[mGKHF]//g' >> $1" || cat
}

# add custom CA cert to system trust store
init_certs() {
  # secret mounted in job container
  local ca_cert="/tls/certs/ca.crt"
  [ -f $ca_cert ] || {
    echo >&2 "CA certificate not found: $ca_cert"
    return 0
  }

  if [ $(id -u) -eq 0 ]; then
    local debian_certs="/usr/local/share/ca-certificates" # Debian/Ubuntu/Alpine
    local fedora_certs="/etc/pki/ca-trust/source/anchors" # Fedora/CentOS/RHEL

    if [ -d $debian_certs ] && \
      command -v update-ca-certificates &> /dev/null; then
        cp $ca_cert $debian_certs
        update-ca-certificates
        return
    elif [ -d $fedora_certs ] && \
      command -v update-ca-trust &> /dev/null; then
        cp $ca_cert $fedora_certs
        update-ca-trust
        return
    fi
  fi

  # no root privileges or update util not found:
  # combine system bundle and custom CA cert, and
  # reference by well-known environment variables
  local dest_bundle="/ci/ca-certs/ca-bundle.crt"
  [ -f $dest_bundle ] || {
    local src_bundles=(
      # one of these bundle files should exist
      "$(ls /etc/ssl/certs/ca-certificates.crt \
            /etc/pki/tls/certs/ca-bundle.crt \
         2> /dev/null | head -1 || true)"
      $ca_cert
    )
    mkdir -p $(dirname $dest_bundle)
    cat "${src_bundles[@]}" > $dest_bundle
  }
  export SSL_CERT_FILE="$dest_bundle"       # OpenSSL/Go/Git/cURL
  export GIT_SSL_CAINFO="$dest_bundle"      # Git
  export CURL_CA_BUNDLE="$dest_bundle"      # cURL
  export PIP_CERT="$dest_bundle"            # Python PIP
  export REQUESTS_CA_BUNDLE="$dest_bundle"  # Python requests
  export NODE_EXTRA_CA_CERTS="$dest_bundle" # Node.js
}

sys_info() {
  section_start 'System Information'
  printf "%s\n------\n%s\n------\n%s\n" \
    "$(lscpu)" "$(free -thw)" "$(df -lh .)"
}

env_vars() {
  section_start 'Environment Variables'
  # use sed to filter out exported functions
  env | sort | sed -En '/^[[:alnum:]_]+=/p' \
      | colorize bash
}

identities() {
  section_start 'Git/OS Identities'
  __identity() {
    local label=$1 name_var=$2 email_var=${3:-_NA_}
    local name="${!name_var}"  email="${!email_var}"

    if [ "$name" ] && [ "$email" ]; then
      echo "$label: $name <$email>"
    elif [ "$name" ]; then
      echo "$label: $name"
    fi
  }
  # https://buildkite.com/docs/pipelines/configure/environment-variables
  __identity "Commit author" BUILDKITE_BUILD_AUTHOR  BUILDKITE_BUILD_AUTHOR_EMAIL
  __identity "Job initiator" BUILDKITE_BUILD_CREATOR BUILDKITE_BUILD_CREATOR_EMAIL
  __identity "Job unblocker" BUILDKITE_UNBLOCKER     BUILDKITE_UNBLOCKER_EMAIL
  id
}

buildah_login() {
  echo -n "$CI_REGISTRY_PASSWORD" | \
    buildah login $CI_REGISTRY      \
      --username  $CI_REGISTRY_USER \
      --password-stdin
}

# <repo> <args>...
# (assumes local image is <repo>:latest)
buildah_build() {
  local repo="${1%:*}"; shift
  local args=(--format docker)

  section_start "Build $repo"
  # use --manifest for  multi-platform build
  # use -t/--tag   for single-platform build
  [[ "$*" == *--manifest* ]] || args+=(-t $repo)
  buildah build "${args[@]}" "$@"
}

# <repo> <tag>
# (assumes local image is <repo>:latest)
buildah_push() {
  local repo="${1%:*}" tag=$2
  local dest="$CI_REGISTRY_PATH/$repo:$tag"

  section_start "Push $repo"
  buildah tag "$repo:latest" $dest
  buildah push $dest
  buildah rmi  $dest
}

# <kind> <namespace>  <resource-name> \
#   <container-type> <container-name> <image>
# kind: Deployment|StatefulSet|DaemonSet
# container-type: container|initContainer
set_k8s_image() {
  local kind=$1 namespace=$2 resource_name=$3
  local container_type=$4 container_name=$5 image=$6
  local pink='\e[1;35m' clear='\e[0m'
  echo -e "Image: $pink$image$clear"

  local index=$(kubectl get $kind -n $namespace $resource_name -o json | \
      jq --arg type $container_type --arg name $container_name  \
        '.spec.template.spec[$type + "s"] | map(.name == $name) | index(true)')
  kubectl patch $kind -n $namespace $resource_name --type=json -p "$(cat <<JSON
[{
  "op":    "replace",
  "path":  "/spec/template/spec/${container_type}s/$index/image",
  "value": "$image"
}]
JSON
  )"
}

# wait for k8s job to complete
# <name> <namespace> <timeout>
wait_k8s_job() (
  args=(job/$1 -n $2 --timeout=$3)
  kubectl wait --for=condition=Complete "${args[@]}" 2> /dev/null &
  completion_pid=$!
  kubectl wait --for=condition=Failed   "${args[@]}" && exit 1 &
  failure_pid=$!
  wait -n $completion_pid $failure_pid
)

# <image-url> [alt-text] [width] [height]
inline_image() {
  # https://buildkite.github.io/terminal-to-html/inline-images
  local args="url=$1" alt="$2" w="$3" h="$4"
  [ "$alt" ] && args+=";alt=$alt"
  [ "$w"   ] && args+=";width=$w"
  [ "$h"   ] && args+=";height=$h"
  echo -e "\033]1338;$args\a"
}

_ci_exit() {
  local rc=$?; set +eux
  if ((rc)) && [ "$CI_DEBUG" ]; then
    # sleep for post-mortem debugging
    local red='\e[0;31m' clear='\e[0m'

    echo -e "+++ $red===== Job Failed =====$clear"
    echo "Sleeping for $CI_DEBUG seconds to allow debugging..."
    sleep $CI_DEBUG
  else
    section_end 'End of pipeline step'
  fi
}
trap _ci_exit EXIT

# https://buildkite.com/docs/pipelines/configure/environment-variables#BUILDKITE_COMMIT_RESOLVED
if [ "$BUILDKITE_COMMIT_RESOLVED" == true ]; then
  export GIT_COMMIT_SHORT_SHA="${BUILDKITE_COMMIT::8}"
fi

set +H # disable history expansion

# export functions for
# use in other scripts
export -f git_root
export -f section_start
export -f section_end
export -f trim_newlines
export -f fake_tty
export -f colorize
export -f tee_noclr
export -f init_certs
export -f buildah_login
export -f buildah_build
export -f buildah_push
export -f set_k8s_image
export -f wait_k8s_job
export -f inline_image
