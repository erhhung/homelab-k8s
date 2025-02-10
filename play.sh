#!/usr/bin/env bash

# Runs Ansible playbook "ansible/main.yml"
# Passes provided args to ansible-playbook

# shellcheck disable=SC2164 # Use cd ... || exit if cd fails

cd "$(dirname "$0")/ansible"

export ANSIBLE_CONFIG=./ansible.cfg
export ANSIBLE_FORCE_COLOR=true

echo -e "\nInstalling roles from requirements...\n"
ansible-galaxy install -r roles/requirements.yml

ansible-playbook "$@" main.yml 2>&1 | tee ansible.log
