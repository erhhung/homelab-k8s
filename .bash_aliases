# Emacs -*-Shell-Script-*- Mode

alias cdd='cd "$OLDPWD"'
alias ll='ls -alFG'
alias lt='ls -latr'
alias la='ls -AG'
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
alias l='less -r'
alias e='emacs'
alias c='crictl'
alias k='kubectl'

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
