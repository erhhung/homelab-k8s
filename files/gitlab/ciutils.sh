# this script is automatically sourced
# by the runner when a build pod starts

# shellcheck disable=SC2148 # Tips depend on target shell
# shellcheck disable=SC2155 # Declare and assign separately
# shellcheck disable=SC2086 # Double quote prevent globbing
# shellcheck disable=SC2046 # Quote to avoid word splitting
# shellcheck disable=SC2206 # Quote to avoid word splitting
# shellcheck disable=SC2015 # A && B || C isn't if-then-else
# shellcheck disable=SC2012 # find is better at non-alphanum

# show root path of current (super) project
git_root() {
  local root="$(git rev-parse --show-superproject-working-tree)"
  [ "$root" ] && echo "$root" || git rev-parse --show-toplevel
}

# <section> <title>
section_start() {
  # https://docs.gitlab.com/ee/ci/jobs/#custom-collapsible-sections
  local section=$1 title="${*:2}" erase_eol='\033[0K' blue='\033[1;34m' clear='\033[0m'
  echo -e "${erase_eol}section_start:$(date +%s):${section}[collapsed=true]\r${erase_eol}$blue===== $title =====$clear"
}

# <section>
section_end() {
  local section=$1 erase_eol='\033[0K'
  echo -e "${erase_eol}section_end:$(date +%s):$section\r$erase_eol"
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
    local debian_certs="/usr/local/share/ca-certificates"
    local fedora_certs="/etc/pki/ca-trust/source/anchors"

    if [ -d $debian_certs ] && \
      command -v update-ca-certificates &> /dev/null; then # Debian/Ubuntu
        cp $ca_cert $debian_certs
        update-ca-certificates
        return
    elif [ -d $fedora_certs ] && \
      command -v update-ca-trust &> /dev/null; then # Fedora/CentOS/RHEL
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
  section_start sys_info 'System Information'
  printf "%s\n------\n%s\n------\n%s\n" \
    "$(lscpu)" "$(free -thw)" "$(df -lh .)"
  section_end sys_info
}

env_vars() {
  section_start env_vars 'Environment Variables'
  # use sed to filter out exported functions
  env | sort | sed -En '/^[[:alnum:]_]+=/p' \
      | colorize  bash
  section_end env_vars
}

identities() {
  section_start identities 'Git/OS Identities'
  echo "Commit author: $CI_COMMIT_AUTHOR"
  echo "Job initiator: $GITLAB_USER_NAME <$GITLAB_USER_EMAIL>"
  id
  section_end identities
}

# wrapper to dump log file if install fails
npm_install() {
  rm -rf ~/.npm/_logs
  npm config set loglevel warn

  if ! npm install --no-fund "$@"; then
    local red='\033[0;31m' clear='\033[0m'
    echo -e "\n$red===== Debug Log =====$clear"
    cat ~/.npm/_logs/*.log
    return 1
  fi
}

buildah_login() {
  echo -n "$CI_REGISTRY_PASSWORD"   |
    buildah login $CI_REGISTRY      \
      --username  $CI_REGISTRY_USER \
      --password-stdin
}

# <tag> <args>...
buildah_build() {
  local section tag=$1; shift
  section="build_${tag%:*}"
  section=${section//-/_}

  section_start $section "Building $tag"
  buildah build -t $tag "$@"
  section_end   $section
}

# <repo> <tag>
# (assumes local image is <repo>:latest)
buildah_push() {
  local dest="$CI_REGISTRY_PATH/$1:$2"
  buildah tag "$1" $dest
  buildah push     $dest
  buildah rmi      $dest
}

# <kind> <namespace>  <resource-name> \
#   <container-type> <container-name> <image>
# kind: Deployment|StatefulSet|DaemonSet
# container-type: container|initContainer
set_k8s_image() {
  local kind=$1 namespace=$2 resource_name=$3
  local container_type=$4 container_name=$5 image=$6
  local pink='\033[1;35m' clear='\033[0m'
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

# sleep for post-mortem
# debugging if job fails
_ci_debug() {
  local rc=$? red='\033[0;31m' clear='\033[0m'
  ((rc)) || return 0

  echo -e "\n$red===== Job Failed =====$clear"
  echo "Sleeping for $CI_DEBUG seconds to allow debugging..."
  sleep $CI_DEBUG
  return $rc
}
[ "$CI_DEBUG" ] && trap _ci_debug EXIT

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
export -f npm_install
export -f buildah_login
export -f buildah_build
export -f buildah_push
export -f set_k8s_image
export -f wait_k8s_job
