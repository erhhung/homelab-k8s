#!/usr/bin/env bash

# the vault password is stored in macOS Keychain
# under item "Home-K8s" for account "ansible-vault"
exec security find-generic-password -l Home-K8s -w
