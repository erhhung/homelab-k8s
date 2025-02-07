#!/usr/bin/env bash

# Run Ansible playbook "ansible/main.yml"

# shellcheck disable=SC2164 # Use cd ... || exit if cd fails

cd "$(dirname "$0")/ansible"

export ANSIBLE_CONFIG=./ansible.cfg

echo -e "\nInstalling roles from requirements...\n"
ansible-galaxy install -r roles/requirements.yml

ansible-playbook main.yml
