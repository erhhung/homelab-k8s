# this file will be added to "keycloakx-admin" ConfigMap and
# mounted into keycloak container at /etc/profile.d/sh.local

# shellcheck disable=SC2148
# shellcheck disable=SC1090
# shellcheck disable=SC2164
# shellcheck disable=SC2086

alias cdd='cd -'
alias ll='ls -alFG --color=always'
alias lt='ls -altr --color=always'

export PATH="$PATH:$HOME/bin"
source <(kc.sh tools completion) 2> /dev/null

cd $HOME
