#!/usr/bin/env bash

# Usage: cert.sh [--opts...] <CN> [SANs...]

# Default expiration is 90 days unless overridden
# using `--exp` option.

# Output .pem & .key files will be saved in ~/certs
# named using the host name part of the common name
# unless overridden using `--out` option.

cd ~

[ "$1" ] || {
  cat<<EOF
Usage: cert.sh [--opts...] <CN> [SANs...]
         opts: step CLI opts, e.g. --kty=RSA
       --exp <days> = expires number of days
       --out <name> = output files bare name
       --p12[=opts] = write single .p12 file
       --pk8[=opts] = key file PKCS#8 [PEM]
         ="opts": openssl pkcs12/pkcs8 opts
EOF
  exit
}

export STEPPATH="$HOME/.step"

step_opts=(
  --force
  --provisioner="erhhung@fourteeners.local"
  --provisioner-password-file="$STEPPATH/admin/pass"
  --not-before="$(date -uI)T00:00:00+00:00"
)
san_list=()

unset exp_days out_bare pkcs12 pkcs8 cn

while [ "$1" ]; do
  case  "$1" in
   --exp*)
     [ "${1:5:1}" == = ] && exp="${1:6}"
     [ "$exp" ] || { exp="$2"; shift; }
     [ "$exp" ] || exit
     exp="$((exp * 24))"
     exp_days="${exp}h"
     ;;
   --out*)
     [ "${1:5:1}" == = ] && out="${1:6}"
     [ "$out" ] || { out="$2"; shift; }
     out=$(basename "$out")
     out_bare="certs/${out%%.*}"
     ;;
   --p12*)
     [ "${1:5:1}" == = ] && p12="${1:6}"
     pkcs12=yes
     ;;
   --pk8*)
     [ "${1:5:1}" == = ] && pk8="${1:6}"
     pkcs8=yes
     ;;
   --*)
     step_opts+=("$1")
     ;;
   *)
     [ "$cn" ]  || cn="$1"
     #  add SAN if not DN
     [[ "$1" != *=* ]] && {
       san_list+=(--san "$1")
       [[ "$1" == *@* ]] && \
         client_auth=yes
     }
     ;;
  esac
  shift
done

[ "$cn" ] || exit

bare_cn() {
  local bn="${cn,,}"
    bn="${bn%%@*}"
    bn="${bn%%.*}"
    bn="${bn%%,*}"
  echo "${bn%% *}"
}

[ "$out_bare" ] || {
  # use CN part only
  # if given full DN
  out_bare="certs/$(bare_cn)"
}
 root_crt="certs/root.crt"
chain_pem="certs/chain.pem"

step_opts+=(
  # supply template values
  # for .Insecure.User.var
  --set commonName="$cn"
  --set clientAuth="$client_auth"

  # default is 90 days (2160 hrs)
  --not-after="${exp_days:-2160h}"
)
echo
step ca certificate "${step_opts[@]}" "${san_list[@]}" "$cn" \
                    "$out_bare.pem" "$out_bare.key" || exit
 cat "$root_crt" >> "$out_bare.pem"

chmod 0644 "$out_bare.pem"
chmod 0600 "$out_bare.key"

echo
step certificate inspect "$out_bare.pem" || exit

if [ "$pkcs12" ]; then
  args=(
    -export
    -out      "$out_bare.p12"
    -passout  "pass:$(bare_cn)"
    -in       "$out_bare.pem"
    -inkey    "$out_bare.key"
    -certfile "$chain_pem"
    -CAfile   "$chain_pem"
     $p12
  )
  openssl pkcs12 "${args[@]}"
  chmod 0644 "$out_bare.p12"

  rm -f "$out_bare.pem" \
        "$out_bare.key"

elif [ "$pkcs8" ]; then
  args=(
    -topk8
    -inform  PEM
    -outform PEM
    -in "$out_bare.key"
    -nocrypt
     $pk8
  )
  openssl pkcs8 "${args[@]}" | \
      sponge "$out_bare.key"
  chmod 0600 "$out_bare.key"
fi

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

# _touch [-t time] <files...>
# -t: digits in multiples of 2 replacing right-most
#     digits of current time in yyyyMMddHHmm format
_touch() {
  local d; d=$(__touch_date "$@") || return
  [ "$1" == '-t' ] && shift 2
  touch -cht "$d" "$@"
}
_touch -t 00 certs "$out_bare".*
