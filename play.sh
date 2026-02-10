#!/usr/bin/env bash

# runs the specified playbooks (refer to comments
# in runlist.sh for how args are parsed to create
# the runlist)

# shellcheck disable=SC2046 # Quote to avoid word splitting
# shellcheck disable=SC2207 # Prefer mapfile to split output
# shellcheck disable=SC2155 # Declare and assign separately
# shellcheck disable=SC2198 # Arrays don't work as operands

cd "$(dirname "$0")"
set -eo pipefail

# replace $@ with updated args list
args="$(./runlist.sh "$@")" || exit
eval "set -- $args"

if [ "${@: -1}" == temp.yml ]; then
  # ensure cleanup of temp.yml
  trap "rm -f temp.yml" EXIT
fi

export ANSIBLE_CONFIG=./ansible.cfg
export ANSIBLE_PRIVATE_KEY_FILE=$HOME/.ssh/$USER.pem
export ANSIBLE_FORCE_COLOR=true

# get playbooks that will be run
get_playbooks() {
  jo PLAYBOOKS="$(jo -a \
    $(for arg in "$@"; do
        if [ "$arg" == temp.yml ]; then
          yq 'map(.tags)[]' temp.yml
        elif [[ $arg == *.yml ]]; then
          basename "${arg%.yml}"
        fi
      done
    ))"
}
# pass extra var to indicate
# playbooks that will be run
extra_vars="$(get_playbooks "$@")"

# install roles from requirements
install_roles() {
  # list of playbooks that use roles
  local use_roles="$(jo -a cluster)"

  jq -n --argjson extra_vars "$extra_vars" \
        --argjson use_roles  "$use_roles"  \
    'halt_error(if any($extra_vars.PLAYBOOKS[]; . as $x |
      $use_roles | index($x)) then 0 else 1 end)' || return 0

  echo -e "\nInstalling roles and collections...\n"
  ansible-galaxy install -r roles/requirements.yml
}
install_roles

# purge facts cache when re-running all playbooks
[ "${@: -1}" == temp.yml ] && [ -f temp.yml ] && \
  diff -q temp.yml main.yml &> /dev/null && \
    rm -f .ansible/facts/*

# strip ANSI color codes
no_color() {
  sed -E 's/(\x1B|\\x1B|\033|\\033)\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g'
}

ansible-playbook "$@" -e "$extra_vars" \
  2>&1 | tee >(no_color > ansible.log)
