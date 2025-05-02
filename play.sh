#!/usr/bin/env bash

# Runs Ansible playbook main.yml unless one or more .yml
# files are specified.  If the last argument is a tag in
# main.yml (playbook without .yml extension), plus a '-'
# suffix (e.g. "storage-"), runs all remaining playbooks
# starting with that playbook.

# shellcheck disable=SC2164 # Use cd ... || exit if cd fails
# shellcheck disable=SC2207 # Prefer mapfile to split output
# shellcheck disable=SC2016 # Expr won't expand in '' quotes
# shellcheck disable=SC2128 # Expanding array without index

cd "$(dirname "$0")"

# require given commands
# to be $PATH accessible
# example: _reqcmds aws jq || return
_reqcmds() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" &> /dev/null && continue
    echo >&2 "Please install \"$cmd\" first!"
    return 1
  done
}

_reqcmds yq || exit $?

export ANSIBLE_CONFIG=./ansible.cfg
export ANSIBLE_FORCE_COLOR=true

echo -e "\nInstalling roles from requirements...\n"
ansible-galaxy install -r roles/requirements.yml

args=("$@")

[[ "${args[*]}" == *.yml* ]] || {
  # check if last arg is tag-
  last=$(( ${#args[@]} -1 ))

  if [[ $last -ge 0 && "${args[last]}" == *- ]]; then
    start="${args[last]%?}" args=("${args[@]::last}")

    # create sliced version of main.yml
    START=$start yq '. as $d | .[] | select(.tags == env(START))
             | path[0] as $i |  $d | .[$i:]' main.yml > temp.yml
    trap "rm -f temp.yml" EXIT
    args+=("temp.yml")
  else
    args+=("main.yml")
  fi
}
ansible-playbook "${args[@]}" 2>&1 | tee ansible.log
