# Emacs -*-Shell-Script-*- Mode

# shellcheck disable=SC2148 # Tips depend on target shell
# shellcheck disable=SC1091 # Not following: not input file
# shellcheck disable=SC2155 # Declare and assign separately
# shellcheck disable=SC2086 # Double quote prevent globbing
# shellcheck disable=SC2207 # Prefer mapfile to split output
# shellcheck disable=SC1090 # Can't follow non-const source

alias sudo='sudo -E '
alias cdd='cd "$OLDPWD"'
alias ll='ls -alFG'
alias lt='ls -latr'
alias la='ls -AG'
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
alias l='less -r'
alias e='emacs'

# helper for _touch and touchall
__touch_date() {
  local d=$(date '+%Y%m%d%H%M.00')
  if [ "$1" != '-t' ]; then
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
  local d; d=$(__touch_date "$@") || return
  [ "$1" == '-t' ] && shift 2
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
  if [ "$1" == '-d' ]; then
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

# show disk usage (use du0/du1 aliases)
_diskusage() {
  local depth=${1:-1} path=${2:-.}
  du -d $depth -x -h "${path/%\//}"     \
    2> >(grep -v 'Permission denied') | \
    sort -h
}
alias du0='_diskusage 0'
alias du1='_diskusage 1'

rsync() {
  local opts=(
    # -vrultO
    --verbose        # increase verbosity
    --recursive      # recurse into directories
    --update         # skip files that are newer on receiver
    --links          # copy symlinks as symlinks
    --times          # preserve times
    --omit-dir-times # omit directories when preserving times
    --progress       # show progress during transfer
  )
  # use "sudo rsync" on "cosmos" in order to
  # set timestamps of files not owned by the
  # SSH user (requires /etc/sudoers setting)
  [[ "$*" =~ (^|\s)(cosmos|home): ]] && \
    opts+=(--rsync-path="sudo rsync")

  "$(which rsync)" "${opts[@]}" "$@"
}

# get max widths of
# one-word  columns
_colwidths() {
  awk '{for (i=1; i<=NF; i++) {l=length($i); if (l>L[i]) L[i]=l;}} END \
       {for (i=1; i<=length(L); i++) {printf L[i] "\n";}}'
}

# format one-word columns
# with each left-justified
cols() {
  local w n i table=$(cat)
  [ "$table" ] || return 0

  w=($(_colwidths <<< "$table"))
  (( n = ${#w[@]} - 2 ))

  local cols fmt=""
  for i in $(seq 0 $n); do
    # %b allows \xNN chars
    fmt+="%-${w[$i]}b  "
  done

  while read -ra cols; do
    printf "$fmt%b\n" "${cols[@]}"
  done <<< "$table"
}

# show TCP ports currently in LISTEN state
# (add lsof to /etc/sudoers with NOPASSWD)
listening() {
  \sudo lsof -nP -iTCP -sTCP:LISTEN +c0 | \
    awk 'NR>1 { # skip header line
           i = split($9, p, ":");
           printf  "%u %s\n", p[i], $1
        }' | sort -n | uniq | cols
}

# show system information
# https://github.com/fastfetch-cli/fastfetch
_fastfetch() {
  # use custom preset if no args provided
  [ "$1" ] || set -- -c $HOME/.config/fastfetch/custom.jsonc
  fastfetch "$@"
}
alias ff='_fastfetch'

# ip output in color
alias ip='ip -c=auto'

venv() {
  local activate="$HOME/.venv/bin/activate"
  [ -f "$activate" ] && \
     . "$activate"   || return 0
}

# =============================================
# === APPLICABLE ONLY AFTER K3S/RKE INSTALL ===
# =============================================
command -v kubectl &> /dev/null || return 0

# set up Bash completion for crictl
command -v crictl &> /dev/null && {
  alias c='crictl'
  . <(crictl completion bash 2> /dev/null)
  complete -F _crictl c
}

alias k='kubectl'
# set up Bash completion for kubectl
. <(kubectl completion bash 2> /dev/null)
complete -F __start_kubectl k

# set up Bash completion for helm
command -v helm &> /dev/null && {
  alias h='helm'
  . <(helm completion bash 2> /dev/null)
  complete -F __start_helm h
}

# usage: rmevicted [args...]
# all args, including -A, are
# passed to "kubectl get pods"
rmevicted() {
  # https://stackoverflow.com/questions/46419163/what-will-happen-to-evicted-pods-in-kubernetes#49167987
  kubectl get pods "$@" -o json | jq '.items[]
    | select(.status.reason != null)
    | select(.status.reason | contains("Evicted"))
    | "kubectl delete pods \(.metadata.name) -n \(.metadata.namespace)"' \
    | xargs -n 1 -r bash -c
}

# only installed on Rancher host
[ -f "$HOME/.rancher_api" ] && \
   . "$HOME/.rancher_api"
