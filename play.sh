#!/usr/bin/env bash

# Run Ansible playbook "ansible/main.yml"

# shellcheck disable=SC2164 # Use cd ... || exit if cd fails

cd "$(dirname "$0")/ansible"

INVENTORY="--inventory=inventory/hosts.ini"
VAULTPASS="--vault-password-file=vaultpass.sh"
ansible-playbook $INVENTORY $VAULTPASS main.yml
