#!/usr/bin/env bash

# vault password stored in macOS "login" Keychain
# under name "Home-K8s" for account "ansible-vault"
exec security find-generic-password -l Home-K8s -w
