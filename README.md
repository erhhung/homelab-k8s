# Erhhung's Home Kubernetes Cluster Configuration

This project manages the configuration and user files for Erhhung's Kubernetes cluster at home.

## Ansible Vault

The Ansible Vault password is stored in macOS Keychain under item "`Home-K8s`" for account "`ansible-vault`".

```bash
cd ansible

export ANSIBLE_CONFIG=./ansible.cfg
VAULTFILE="group_vars/all/vault.yml"

ansible-vault create $VAULTFILE
ansible-vault edit   $VAULTFILE
```

Variables stored in Ansible Vault:

* `ansible_become_pass`
* `k3s_token`
* `rke2_token`

## Connections

All managed hosts are running **Ubuntu 24.04** with SSH key from https://github.com/erhhung.keys already authorized.  

Ansible will authenticate as user `erhhung` using private key "`~/.ssh/erhhung.pem`";  
however, all privileged operations using `sudo` will require the password stored in Vault.

## Playbooks

Set the config variable first for the `ansible-playbook` commands below:

```bash
export ANSIBLE_CONFIG=./ansible.cfg
```

1. Install required packages

    ```bash
    ansible-playbook packages.yml
    ```

2. Configure system settings

    2.1. **Host**: host name, time zone, and locale  
    2.2. **Network**: DNS servers and search domains  
    2.3. **Login**: Customize login MOTD messages

    ```bash
    ansible-playbook basics.yml
    ```

3. Set up admin user's home directory

    3.1. **Dot files**: `.bash_aliases`, `.emacs`

    ```bash
    ansible-playbook files.yml
    ```

4. Set up Rancher Server on K3s cluster

    ```bash
    ansible-playbook rancher.yml
    ```

5. Set up Kubernetes cluster with RKE2

    Installs RKE2 with single control plane node
    and 3 worker nodes.

    ```bash
    ansible-playbook cluster.yml
    ```

Alternatively, **run all 5 playbooks** from the project root folder:

```bash
./play.sh
```

### Optional Playbooks

1. Shut down all/specific VMs

    ```bash
    ansible-playbook shutdownvms.yml [-e target_hosts={group|host|,...}]
    ```

2. Create/delete VM snapshots

    2.1. Create new snaphots

    ```bash
    ansible-playbook snapshotvms.yml [-e target_hosts={group|host|,...}] \
                                     <-e create_desc="snapshot description">
    ```

    2.2. Delete old snaphots

    ```bash
    ansible-playbook snapshotvms.yml [-e target_hosts={group|host|,...}] \
                                     <-e delete_date="YYYY-mm-dd* prefix">
                                     <-e delete_desc="text to search for">
    ```

3. Restart all/specific VMs

    ```bash
    ansible-playbook startvms.yml [-e target_hosts={group|host|,...}]
    ```
