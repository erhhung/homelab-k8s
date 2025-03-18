# Erhhung's Home Kubernetes Cluster Configuration

This project configures and provisions Erhhung's high-availability Kubernetes cluster at home using Rancher.

The top-level Ansible playbook `main.yml` run by `play.sh` will provision 5 VM hosts (`rancher` and `k8s1`..`k8s4`)
in the XCP-ng "Home" pool, all running Ubuntu Server 24.04 Minimal without customizations besides basic networking
and authorized SSH key for user `erhhung`.

A single-node K3s Kubernetes cluster will be installed on host `rancher` along with Rancher Server on that cluster.
A 4-node RKE2 Kubernetes cluster with a high-availability control plane on a virtual IP will be installed on hosts
`k8s1`..`k8s4`. The Longhorn distributed block storage engine will also be installed on the RKE2 cluster to manage
a pool of LVM logical volumes created on each cluster node. Finally, one or more virtual clusters running K0s will
be created for testing and learning purposes.

The Rancher Server UI at https://rancher.fourteeners.local will be provisioned with a TLS certificate from Erhhung's
private CA server at pki.fourteeners.local.

## Cluster Topology

<div style="text-align: center">
<img src="./topology.drawio.svg" alt="topology.drawio.svg" />
</div>

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
    2.4. **Certs**: Add CA certificates to trust store

    ```bash
    ansible-playbook basics.yml
    ```

3. Set up admin user's home directory

    3.1. **Dot files**: `.bash_aliases`, `.emacs`

    ```bash
    ansible-playbook files.yml
    ```

4. Set up **Rancher Server** on a single-node **K3s** cluster

    ```bash
    ansible-playbook rancher.yml
    ```

5. Set up **Kubernetes cluster** with **RKE**

    Installs **RKE2** with a single control plane node and 3 worker nodes, all permitting workloads,  
    or RKE2 in HA mode with 3 control plane nodes and 1 worker node, all permitting workloads.  
    _In HA mode, the cluster will be accessible thru a virtual IP address courtesy of `kube-vip`._

    ```bash
    ansible-playbook cluster.yml
    ```

6. Set up **Longhorn** dynamic PV provisioner

    6.1. Create a pool of LVM logical volumes  
    6.2. Install Longhorn storage components  
    6.3. Install NFS dynamic PV provisioners

    ```bash
    ansible-playbook storage.yml
    ```

7. Create resources from manifest files

    **IMPORTANT**: Resource manifests must specify the namespaces they wished to be installed  
    into because the playbook simply applies each one without targeting a specific namespace.

    ```bash
    ansible-playbook manifests.yml
    ```

8. Set up **Harbor** private container registry

    ```bash
    ansible-playbook harbor.yml
    ```

9. Create **virtual clusters** in RKE running **K0s**

    ```bash
    ansible-playbook vclusters.yml
    ```

Alternatively, **run all playbooks** automatically in order:

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

## Roadmap

These are additional components to be deployed:

- [X] [NFS Dynamic Provisioners](https://computingforgeeks.com/configure-nfs-as-kubernetes-persistent-volume-storage/) — create PVs on NFS shares
    * Install on K3s and RKE clusters using [`nfs-subdir-external-provisioner`](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/) Helm chart
- [X] [Harbor Container Registry](https://goharbor.io/) — private container registry
    * Install into the same K3s cluster as Rancher Server using [`harbor/harbor`](https://github.com/goharbor/harbor-helm/) Helm chart
- [ ] [Argo CD Declarative GitOps](https://argo-cd.readthedocs.io/) — manage deployment of other applications in the main RKE cluster
- [ ] [Prometheus Monitoring Stack](https://github.com/prometheus-operator/kube-prometheus) — Prometheus, Grafana, and rules using the Prometheus Operator
    * Install into the main RKE cluster using [`kube-prometheus-stack`](https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/README.md) Helm chart
- [ ] [Backstage Developer Portal](https://backstage.io/) — software catalog hosted in the main RKE cluster
