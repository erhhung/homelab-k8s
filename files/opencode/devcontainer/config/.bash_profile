# this file is APPENDED to $HOME/.bash_profile from the base image

# shellcheck disable=SC2148 # Tips depend on target shell
# shellcheck disable=SC1090 # Can't follow non-const source
# shellcheck disable=SC1091 # Not following: not input file
# shellcheck disable=SC2128 # Expanding array without index
# shellcheck disable=SC2155 # Declare and assign separately
# shellcheck disable=SC2086 # Double quote prevent globbing
# shellcheck disable=SC2206 # Quote to avoid word splitting
# shellcheck disable=SC2207 # Prefer mapfile to split output
# shellcheck disable=SC2015 # A && B || C isn't if-then-else

# disable C-s/C-q flow control!
stty -ixon

[ "$TERM_PROGRAM" == vscode ] && \
  . <(code --locate-shell-integration-path bash)

# https://github.com/trapd00r/LS_COLORS#installation
. <(dircolors -b "$HOME/.dircolors")

# https://mise.jdx.dev/cli/activate.html#mise-activate
. <(mise activate bash)

# https://github.com/junegunn/fzf#setting-up-shell-integration
. <(fzf --bash)

# https://github.com/lincheney/fzf-tab-completion#bash
[ -f "$XDG_CONFIG_HOME/fzf/fzf-bash-completion.sh" ] && \
   . "$XDG_CONFIG_HOME/fzf/fzf-bash-completion.sh"
bind -x '"\t": fzf_bash_completion'

_fzf_bash_completion_loading_msg() {
  printf '\033[38;5;42m╍╍╍╍╍ LOADING MATCHES ╍╍╍╍╍\033[0m'
}

# https://github.com/ajeetdsouza/zoxide#installation
. <(zoxide init --cmd cd bash)

alias omp &> /dev/null || {
  alias omp='oh-my-posh'

  OMP_THEME="$XDG_CONFIG_HOME/oh-my-posh/theme.yaml"
  ompinit() {
    . <(oh-my-posh init bash --config $OMP_THEME)
  }
  ompinit
}

# clear terminal buffer and screen
c() { printf '\e[2J\e[3J\e[H'; }

alias l=bat
alias f=joshuto
alias p3=python3
alias dt='code --wait --diff'
alias b='buildah '
alias bi='b images'
alias bp='b rmi --prune'

# show disk usage (du0/du1 aliases)
_diskusage() {
  local depth=${1:-1} path=${2:-.}
  du -d $depth -x -h "${path/%\//}" 2> \
     >(grep -v 'Permission denied') | \
       sort -h
}
alias du0='_diskusage 0'
alias du1='_diskusage 1'

# helper for _touch and touchall
__touch_date() {
  local d=$(date '+%Y%m%d%H%M.00')
  if [ "$1" != -t ]; then
    echo "$d"
    return
  fi
  local t=${2// /}; t=${t//-/} t=${t//:/}
  if [[ ! "$t" =~ ^[0-9]{0,12}$ ]]; then
    echo >&2 'Custom time must be all digits!'
    return 1
  fi
  if [ $((${#t} % 2)) -eq 1 ]; then
    echo >&2 'Even number of digits required!'
    return 1
  fi
  local n=$((12 - ${#t}))
  echo "${d:0:$n}$t.00"
}

# usage: _touch [-t time] <files...>
# -t: digits in multiples of 2 replacing right-most
#     digits of current time in yyyyMMddHHmm format
_touch() {
  local d=$(__touch_date "$@") || return
  [ "$1" == -t ] && shift 2
  touch -cht "$d" "$@"
}
alias t='_touch '
alias t0='t -t 00'

# recursively touch files & directories
# usage: touchall [-d] [-t time] [path]
# -d: touch directories only
# -t: digits in multiples of 2 replacing right-most
#     digits of current time in yyyyMMddHHmm format
touchall() {
  local d fargs=()
  if [ "$1" == -d ]; then
    fargs=(-type d); shift
  fi
  d=$(__touch_date "$@") || return
  [ "$d" ] && shift 2
  find "${@:-.}" "${fargs[@]}" -exec touch -cht "$d" "{}" \;
}
alias ta='touchall '
alias ta0='ta -t 00'
alias tad='ta -d '
alias tad0='tad -t 00'

rsync() {
  local opts=(
    # -vrultO
    --verbose        # increase verbosity
    --recursive      # recurse into directories
  # --update         # skip files that are newer on receiver
    --links          # copy symlinks as symlinks
    --times          # preserve times
    --omit-dir-times # omit directories when preserving times
    --progress       # show progress during transfer
  )
  /usr/bin/rsync "${opts[@]}" "$@"
}

# venv [dir]
venv() {
  local use_uv dir="${1:-.venv}"
  use_uv=$(command -v uv 2> /dev/null)
  [ -f ./"$dir"/bin/activate ] || {
    [ "$use_uv" ] && uv venv "$dir" || \
             python3 -m venv "$dir"
  }
  . ./"$dir"/bin/activate
}

# merge read-only ~/.kube/config-vclusters
# into writable ~/.kube/config for kubectx
(
kubecfg=$HOME/.kube/config
kubecfg_vc=$kubecfg-vclusters
kubectx_vc=$(KUBECONFIG=$kubecfg_vc \
  kubectl config view -o jsonpath='{.contexts[0].name}')

KUBECONFIG=$kubecfg \
  kubectl config view -o jsonpath='{range .contexts[*]}{.name}{"\n"}{end}' | \
  grep -q "^$kubectx_vc$" || \
KUBECONFIG=$kubecfg:$kubecfg_vc \
  kubectl config view --merge --flatten | sponge $kubecfg
)
alias k='kubecolor'
alias kcx='kubectx'
alias kns='kubens'

complete -o default -F __start_kubectl kubecolor
complete -o default -F __start_kubectl k

# shellcheck disable=SC2120
__container_shell_init_script() {
  # do NOT use any single quotes!
  cat <<"EOT"
# use /tmp if $HOME is read-only
[ -w $HOME ] || export HOME=/tmp
cd $HOME
touch .hushlogin
cat <<"EOF" > .profile
# get user name via "id" in case uid has no name
PS1="\[\033[1;36m\]\$(id -un 2> /dev/null)\[\033[1;31m\]@\[\033[1;32m\]\h:\[\033[1;35m\]\w\[\033[1;31m\]\$\[\033[0m\] "
alias cdd="cd \$OLDPWD"
alias  ls="ls --color=auto "
alias  ll="ls -alF "
alias  lt="ll -tr "
alias   l="less"
# load Bash dot files if provided by container
[ -f $HOME/.bash_profile ] && . $HOME/.bash_profile
[ -f $HOME/.bash_aliases ] && . $HOME/.bash_aliases
EOF
EOT
  cat <<EOT
$@ # run any additional commands
(hash bash 2> /dev/null) && exec bash --rcfile ~/.profile || exec sh -l
EOT
}

# kubectl run -it --rm bash/sh
# ksh [image] [@host] [opts...]
# image: use Harbor if prefixed ./
#  host: use nodeSelector hostname
# default image is ./al2023-devops
ksh() {
  local args=() opts=() image pod

  image=${1:-.}   # use default DevOps image on Harbor
  [[ "$image" =~ ^\.$|^@.+ ]] && image=./al2023-devops
  [[ "$image" == ./*       ]] && \
    image="harbor.fourteeners.local/library/${image:2}"

  [[ "$2" == @* ]] && shift
  [[ "$1" == @* ]] && {
    opts+=( # run pod on host
      --overrides="$(cat <<EOT
{
  "apiVersion": "v1",
  "spec": {
    "nodeSelector": {
      "kubernetes.io/hostname": "${1:1}"
    }
  }
}
EOT
      )"
    )
    shift
  }
  # decorate pod name with random chars
  # to avoid collision with similar pod
  printf -v pod "%s-temp-admin-%04d" $USER $((RANDOM % 10000))
  args=(
    # --namespace=default
    --labels="app=temp-admin"
    --pod-running-timeout=5m
    --rm -it "${@:2}"
    --restart=Never
    --image=$image
    "${opts[@]}"
    --command
    --quiet
  )
  kubectl run $pod "${args[@]}" -- \
    sh -c "$(__container_shell_init_script)"
}

# kexec <pod>[:container] [opts] [-- command]
# (completion is defined
# in ~/.bash_completion)
kexec() {
  # ensure kubectl installed
  _reqcmds kubectl || return

  local pod=$1; shift

  local o opts=()
  while [ "$1" ]; do
    o=$1; shift
    # extra args for docker command
    [ "$o" != -- ] && opts+=($o) || break
  done

  if [[ "$pod" =~ ^[^:]+:[^:]+$ ]]; then
    # pod:container => pod -c container
    opts=(-c "${pod/*:/}" "${opts[@]}")
    pod=${pod/:*/}
  else
    # if there's more than 1 container, choose first one to avoid warning
    o=($(kubectl get pod "$pod" -o jsonpath='{.spec.containers[*].name}'))
    opts=(-c $o "${opts[@]}")
  fi

  if [[ -z ${1+x} ]]; then # run shell if no command
    set -- sh -c "$(__container_shell_init_script)"
  fi
  kubectl exec -it "${opts[@]}" "$pod" -- "$@"
}
