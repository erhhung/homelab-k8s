# Erhhung's Home Kubernetes Cluster Configuration

This project manages the configuration and user files for Erhhung's _high-availability_ Kubernetes cluster at home.

## Ansible Vault

The Ansible Vault password is stored in macOS Keychain under item "`Home-K8s`" for account "`ansible-vault`".

```bash
export ANSIBLE_CONFIG=./ansible.cfg
VAULTFILE="group_vars/all/vault.yml"

ansible-vault create $VAULTFILE
ansible-vault edit   $VAULTFILE
```

Variables stored in Ansible Vault:

* `ansible_become_pass`
* `rancher_admin_pass`
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

    1.1. **Tools**: `emacs`, `jq`, `yq`, `git`, and `helm`  
    1.2. **Python**: Pip packages in user **virtualenv**  
    1.3. **Helm**: Helm plugins: e.g. `helm-diff`

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

4. Set up Rancher Server on a single-node **K3s** cluster

    ```bash
    ansible-playbook rancher.yml
    ```

5. Set up Kubernetes cluster with RKE

    Installs **RKE2** with a single control plane node and 3 worker nodes, all permitting workloads,  
    or RKE2 in HA mode with 3 control plane nodes and 1 worker node, all permitting workloads.  
    _In HA mode, the cluster will be accessible thru a virtual IP address courtesy of `kube-vip`._

    ```bash
    ansible-playbook cluster.yml
    ```

6. Create logical volume for local PVs

    ```bash
    ansible-playbook storage.yml
    ```

7. Create resources from manifest files

    **IMPORTANT**: Resource manifests must specify the namespaces they wished to be installed  
    into because the playbook simply applies each one without targeting a specific namespace.

    ```bash
    ansible-playbook manifests.yml
    ```

8. Create virtual clusters within RKE running **K0s**

    ```bash
    ansible-playbook vclusters.yml
    ```

Alternatively, **run all 8 playbooks** automatically in order:

```bash
# pass options like -v and --step
./play.sh [ansible-playbook-opts]
```

Output from `play.sh` will be logged in "`ansible.log`".

### Optional Playbooks

1. Shut down all/specific VMs

    ```bash
    ansible-playbook shutdownvms.yml [-e targets={group|host|,...}]
    ```

2. Create/revert/delete VM snapshots

    2.1. Create new snaphots

    ```bash
    ansible-playbook snapshotvms.yml [-e targets={group|host|,...}] \
                                      -e '{"desc":"text description"}'
    ```

    2.2. Revert to snapshots

    ```bash
    ansible-playbook snapshotvms.yml  -e do=revert \
                                     [-e targets={group|host|,...}]  \
                                      -e '{"desc":"text to search"}' \
                                     [-e '{"date":"YYYY-mm-dd prefix"}']
    ```

    2.3. Delete old snaphots

    ```bash
    ansible-playbook snapshotvms.yml  -e do=delete \
                                     [-e targets={group|host|,...}]  \
                                      -e '{"desc":"text to search"}' \
                                      -e '{"date":"YYYY-mm-dd prefix"}'
    ```

3. Restart all/specific VMs

    ```bash
    ansible-playbook startvms.yml [-e targets={group|host|,...}]
    ```

## Troubleshooting

Ansible's [ad-hoc commands](https://docs.ansible.com/ansible/latest/command_guide/intro_adhoc.html#managing-services) are useful in these scenarios.

1. Restart Kubernetes cluster services on all nodes

    ```bash
    ansible rancher       -m ansible.builtin.service -b -a "name=k3s         state=restarted"
    ansible control_plane -m ansible.builtin.service -b -a "name=rke2-server state=restarted"
    ansible workers       -m ansible.builtin.service -b -a "name=rke2-agent  state=restarted"
    ```

    _**NOTE:** substitute target hosts with `control_plane_ha` and `workers_ha` if the RKE cluster was deployed in HA mode._
