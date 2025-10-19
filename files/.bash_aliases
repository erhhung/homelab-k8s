# Emacs -*-Shell-Script-*- Mode

# shellcheck disable=SC2148 # Tips depend on target shell
# shellcheck disable=SC1090 # Can't follow non-const source
# shellcheck disable=SC1091 # Not following: not input file
# shellcheck disable=SC2155 # Declare and assign separately
# shellcheck disable=SC2086 # Double quote prevent globbing
# shellcheck disable=SC2206 # Quote to avoid word splitting
# shellcheck disable=SC2207 # Prefer mapfile to split output

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

# show TCP ports in LISTEN state
listening() {
  # lsof has setuid bit set, so
  # it runs as root without sudo
  lsof -nP -iTCP -sTCP:LISTEN +c0 | \
    awk 'NR>1 { # skip header line
           i = split($9, p, ":");
           printf  "%u %s\n", p[i], $1
        }' | sort -n | uniq | cols
}

# check TCP port connectivity
# usage: port <port> [host]
# default host is localhost
port() {
  [ "$1" ] || {
    cat <<EOT

Check TCP port connectivity
Usage: port <port> [host]
Default host is localhost

EOT
    return 0
  }
  local port=$1 host=${2:-localhost}
  if [ "${port-0}" -eq "${port-1}" ] 2> /dev/null; then
    nc -zv -w1 "$host"  "$port" 2>&1 | \
      head -n2 | tail -n1  | colrm 1 6
  else
    echo >&2 "Invalid port!"
    return 1
  fi
}

# show details of certificate chain from
# stdin, PEM file, website or K8s secret
cert() {
  local stdin host port args
  if [ -p /dev/stdin ]; then
    stdin=$(cat)
  else
    [ "$1" ] || {
      cat <<EOT

Show details of certificate chain from
stdin, PEM file, website or K8s secret

Usage: cert [file | host=. [port=443]]
       cert -k [namespace/]<tls-secret>
All args ignored if stdin is available

cert < website.pem       # standard input
cert   website.pem       # local PEM file
cert   website.com       # website.com:443
cert   website.com:8443  # website.com:8443
cert   8443              # localhost:8443
cert   .                 # localhost:443
cert -k namespace/secret # K8s "tls.crt"
EOT
      echo; return 0
    }
    # certs from K8s secret
    if [ "$1" == -k ]; then
      local secret=$2
      [[ "$secret" == */* ]] && {
        args+=(-n ${secret%/*})
        secret=${secret#*/}
      }
      stdin=$(kubectl get secret $secret "${args[@]}" \
        -o jsonpath='{ .data.tls\.crt }' | base64 -d)
    else
      host=${1:-localhost}
      [ "$host" == . ] && host=localhost
      # strip scheme & path if is an URL
      host=${host#*://}; host=${host%%/*}
      port=${2:-443}

      # handle host:port syntax
      [[ "$host" == *:* ]] && {
        port=${host#*:}
        host=${host%%:*}
      }
      # handle if only port number given
      if [ "${host-0}" -eq "${host-1}" ] 2> /dev/null; then
        port=$host
        host=localhost
      fi
      # use proxy for s_client if needed
      [ "$http_proxy" ] && args+=(-proxy
        $(cut -d/ -f3- <<< "$http_proxy")
      )
    fi
  fi

  local cert="" line out
  while read -r line; do
    # concatenate lines in each cert block
    # until ";" delimiter from awk command
    if [ "$line" == ';' ]; then
      out=$(openssl x509 -text -inform pem -noout <<< "$cert")
      [ "$out" ] && echo -e "\n$out"
      cert=""
    else
      cert+="$line"$'\n'
    fi
  done < <(
    if [ "$stdin" ]; then
      # certs from stdin
      echo "$stdin"
    elif [ -f "$host" ]; then
      # certs from file
      cat "$host"
    else
      # certs from host
      args=(
        s_client "${args[@]}"
        -connect "$host:$port"
        -showcerts
      )
      openssl "${args[@]}" <<< ""
    fi 2> /dev/null | \
      awk '
      /-----BEGIN CERTIFICATE-----/,
        /-----END CERTIFICATE-----/
      ' | \
      awk 'BEGIN {
        cert=""
        }
        /-----BEGIN CERTIFICATE-----/ {
          cert=$0
          next
        }
        /-----END CERTIFICATE-----/ {
          # output ";" as delimiter
          # between each cert block
          cert=cert"\n"$0"\n;"
          print cert
          cert=""
          next
        } {
          cert=cert"\n"$0
        }'
  )
  [ "$out" ] && echo
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

# export environment variables
# in ~/.bash_env.d/*.env files
envs() {
  # expand to nothing if
  # there are no matches
  shopt -s nullglob
  local file line

  for file in "$BASH_ENV_DIR"/*.env; do
    while read -r line; do
      # skip comment, blank or invalid lines
      # (variable names must be capitalized)
      [[ "$line" =~ ^[A-Z_].*$ ]] || continue
      eval "export $line"
    done < "$file"
  done
}

export BASH_ENV_DIR="$HOME/.bash_env.d"
mkdir -p "$BASH_ENV_DIR" && envs

venv() {
  local activate="$HOME/.venv/bin/activate"
  [ -f "$activate" ] && \
     . "$activate"   || return 0
}

# =============================================
# === APPLICABLE ONLY AFTER K3S/RKE INSTALL ===
# =============================================

command -v kubectl &> /dev/null && {
  alias k='kubectl'
  . <(kubectl completion bash 2> /dev/null)
  complete -o default -F __start_kubectl k
}

command -v helm &> /dev/null && {
  alias h='helm'
  . <(helm completion bash 2> /dev/null)
  complete -o default -F __start_helm h
}

command -v crictl &> /dev/null && {
  alias c='crictl'
  . <(crictl completion bash 2> /dev/null)
  complete -o default -F _crictl c
}

command -v cmctl &> /dev/null && \
  . <(cmctl completion bash 2> /dev/null)

command -v harbor &> /dev/null && {
  alias hls='harbor repo list library'
  . <(harbor completion bash 2> /dev/null)
}

command -v mc &> /dev/null && {
  complete -C "$(which mc)" mc
  export MC_CONFIG_DIR="$HOME/.config/minio"
  export MC_DISABLE_PAGER=1
}

command -v velero &> /dev/null && \
  . <(velero completion bash 2> /dev/null)

command -v istioctl &> /dev/null && \
  . <(istioctl completion bash 2> /dev/null)

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
command -v rancher &> /dev/null && \
  [ -f "$HOME/.rancher_api" ]   && \
     . "$HOME/.rancher_api"
