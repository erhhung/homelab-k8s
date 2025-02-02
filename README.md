# Erhhung's Home Kubernetes Cluster Configuration

This project manages the configuration and user files for Erhhung's Kubernetes cluster at home.

## Ansible Vault

Store `ansible_become_pass` in Ansible Vault:

```bash
VAULT_FILE="group_vars/all/vault.yml"
VAULT_PASS="--vault-password-file=vaultpass.sh"

cd ansible
ansible-vault create $VAULT_FILE $VAULT_PASS
ansible-vault edit   $VAULT_FILE $VAULT_PASS
```

The Ansible Vault password is stored in macOS Keychain under item "`Home-K8s`" for account "`ansible-vault`".

## Connections

All managed hosts are running **Ubuntu 24.04** with SSH key from https://github.com/erhhung.keys already authorized.  
Ansible will authenticate as user `erhhung` using private key "`~/.ssh/erhhung.pem`";  
however, all privileged operations using `sudo` will require the password stored in Vault.

## Playbooks

1. Install required packages

    ```bash
    VAULT_PASS="--vault-password-file=vaultpass.sh"
    ansible-playbook $VAULT_PASS -i hosts.ini packages.yml
    ```

2. Configure system settings

   2.1. **Host**: host name, time zone, and locale  
   2.2. **Network**: DNS servers and search domains  
   2.3. **Login**: Customize login MOTD messages

    ```bash
    VAULT_PASS="--vault-password-file=vaultpass.sh"
    ansible-playbook $VAULT_PASS -i hosts.ini basics.yml
    ```

3. Set up admin user's home directory

    3.1. **Dot files**: `.bash_aliases`, `.emacs`

    ```bash
    VAULT_PASS="--vault-password-file=vaultpass.sh"
    ansible-playbook $VAULT_PASS -i hosts.ini files.yml
    ```
