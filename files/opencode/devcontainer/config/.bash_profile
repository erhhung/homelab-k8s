# this file is APPENDED to $HOME/.bash_profile from the base image

# shellcheck disable=SC2148 # Tips depend on target shell
# shellcheck disable=SC1090 # Can't follow non-const source
# shellcheck disable=SC2155 # Declare and assign separately
# shellcheck disable=SC2086 # Double quote prevent globbing
# shellcheck disable=SC2015 # A && B || C isn't if-then-else

# disable C-s/C-q flow control!
stty -ixon

. <(dircolors -b "$HOME/.dircolors")

# clear terminal buffer and screen
c() { printf '\e[2J\e[3J\e[H'; }

alias l=bat
alias f=joshuto
alias b='buildah '
alias bi='b images'
alias bp='b rmi --prune'
alias dt='code --wait --diff'
alias p3=python3

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
alias kcx='kubectx'
alias kns='kubens'
