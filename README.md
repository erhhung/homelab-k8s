# Erhhung's Home Kubernetes Cluster

This Ansible-based project provisions Erhhung's high-availability Kubernetes cluster `homelab` using Rancher, and installs services to monitor IoT appliances and to deploy other personal projects.

The approach taken on all service deployments is to treat the clusters as a **production** environment _(to the extent possible with limited resources and scaling capacity across a few mini PCs)_. That means TLS everywhere and requiring authenticated user access, scraping metrics, and configuring dashboards and alerts.

## Overview

The top-level Ansible playbook `main.yml` run by `play.sh` will provision 5 VM hosts (`rancher` and `k8s1`..`k8s4`)
in the existing XCP-ng `Home` pool, all running Ubuntu Server 24.04 Minimal without customizations besides basic networking
and authorized SSH key for the user `erhhung`.

A single-node K3s Kubernetes cluster will be installed on host `rancher` alongside with Rancher Server on that cluster, and a 4-node RKE2 Kubernetes cluster with a high-availability control plane using virtual IPs will be installed on hosts
`k8s1`..`k8s4`. Longhorn and NFS storage provisioners will be installed in each cluster to manage a pool of LVM logical volumes on each node, and to expand the overall storage capacity on the QNAP NAS.

All cluster services will be provisioned with TLS certificates from Erhhung's private CA server at `pki.fourteeners.local` or its faster mirror at `cosmos.fourteeners.local`.

## Cluster Topology

<p align="center">
<img src="images/topology.drawio.svg" alt="topology.drawio.svg" />
</p>

## Cluster Services

<p align="center">
<img src="images/services.drawio.svg" alt="services.drawio.svg" />
</p>

## Service Endpoints

|                       Service Endpoint | Description
|---------------------------------------:|:----------------------
|      https://rancher.fourteeners.local | Rancher Server console
|       https://harbor.fourteeners.local | Harbor OCI registry
|        https://minio.fourteeners.local | MinIO console
|           https://s3.fourteeners.local | MinIO S3 API
|      opensearch.fourteeners.local:9200 | OpenSearch _(HTTPS only)_
|       https://kibana.fourteeners.local | OpenSearch Dashboards
|        postgres.fourteeners.local:5432 | PostgreSQL via Pgpool _(mTLS only)_
|          https://sso.fourteeners.local | Keycloak IAM console
|          valkey.fourteeners.local:6379 <br/> valkey<i>{1..6}</i>.fourteeners.local:6379 | Valkey cluster _(mTLS only)_
|      https://grafana.fourteeners.local | Grafana dashboards
|      https://metrics.fourteeners.local | Prometheus UI _(Keycloak SSO)_
|       https://alerts.fourteeners.local | Alertmanager UI _(Keycloak SSO)_
|       https://thanos.fourteeners.local | Thanos Query UI
|  https://rule.thanos.fourteeners.local <br/> https://store.thanos.fourteeners.local <br/> https://bucket.thanos.fourteeners.local <br/> https://compact.thanos.fourteeners.local | Thanos component status UIs
|        https://kiali.fourteeners.local | Kiali console _(Keycloak SSO)_
|       https://argocd.fourteeners.local | Argo CD console
|  http://ollama.fourteeners.local:11434 | Ollama LLM server

## Installation Sources

- [X] [K3s Kubernetes Cluster](https://k3s.io/) — lightweight Kubernetes distro for resource-constrained environments
    * Install on the `rancher` host using the official [install script](https://docs.k3s.io/quick-start#install-script)
- [X] [Rancher Cluster Manager](https://ranchermanager.docs.rancher.com/) — provision (or import), manage, and monitor Kubernetes clusters
    * Install on K3s cluster using the [`rancher`](https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/install-upgrade-on-a-kubernetes-cluster#install-the-rancher-helm-chart) Helm chart
- [X] [RKE2 Kubernetes Cluster](https://rke2.io/) — Kubernetes distribution with focus on security and compliance
    * Install on hosts `k8s1`-`k8s4` using the [RKE2 Ansible Role](https://github.com/lablabs/ansible-role-rke2) with HA mode enabled
- [X] [Certificate Manager](https://cert-manager.io/) — X.509 certificate management for Kubernetes
    * Install on K3s and RKE clusters using the [`cert-manager`](https://cert-manager.io/docs/installation/helm/) Helm chart
    * [X] Connect to Step CA `pki.fourteeners.local` using the [`step-issuer`](https://github.com/smallstep/helm-charts/tree/master/step-issuer) Helm chart
    * [ ] Connect to Step CA `pki.fourteeners.local` as an [ACME](https://cert-manager.io/docs/configuration/acme/) `ClusterIssuer`
- [X] [Longhorn Block Storage](https://longhorn.io/docs/latest/what-is-longhorn/) — distributed block storage for Kubernetes
    * Install on main RKE cluster using the [`longhorn`](https://longhorn.io/docs/latest/deploy/install/install-with-helm/) Helm chart
- [X] [NFS Dynamic Provisioner](https://computingforgeeks.com/configure-nfs-as-kubernetes-persistent-volume-storage/) — create persistent volumes on NFS shares
    * Install on K3s and RKE clusters using the [`nfs-subdir-external-provisioner`](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/) Helm chart
- [X] [Harbor Container Registry](https://goharbor.io/) — private OCI container and [Helm chart](https://goharbor.io/docs/main/working-with-projects/working-with-oci/working-with-helm-oci-charts/) registry
    * Install on K3s cluster using the [`harbor`](https://github.com/goharbor/harbor-helm/) Helm chart
- [X] [MinIO Object Storage](https://github.com/minio/minio) — S3-compatible object storage with console
    * Install on main RKE cluster using the [MinIO Operator](https://min.io/docs/minio/kubernetes/upstream/operations/install-deploy-manage/deploy-operator-helm.html) and [MinIO Tenant](https://min.io/docs/minio/kubernetes/upstream/operations/install-deploy-manage/deploy-minio-tenant-helm.html) Helm charts
- [X] [Velero Backup & Restore](https://velero.io/docs/latest/basic-install) — back up and restore persistent volumes
    * Install on main RKE cluster using the [Velero](https://github.com/vmware-tanzu/helm-charts/tree/main/charts/velero) Helm chart
- [X] [Node Feature Discovery](https://kubernetes-sigs.github.io/node-feature-discovery) — label nodes with available hardware features, like GPUs
    * Install on K3s and RKE clusters using the [`node-feature-discovery`](https://kubernetes-sigs.github.io/node-feature-discovery/stable/deployment/helm.html) Helm chart
    * [X] Install [Intel Device Plugins](https://intel.github.io/intel-device-plugins-for-kubernetes) using the [`intel-device-plugins-operator`](https://github.com/intel/helm-charts/tree/main/charts/device-plugin-operator) Helm chart
    * [ ] Install [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/overview.html) on RKE cluster ... _when I procure an NVIDIA card_ :(
- [X] [OpenSearch Logging Stack](https://opensearch.org/docs/latest/) — aggregate and filter logs using OpenSearch and Fluent Bit
    * Install on main RKE cluster using the [`opensearch`](https://opensearch.org/docs/latest/install-and-configure/install-opensearch/helm/) and [`opensearch-dashboards`](https://opensearch.org/docs/latest/install-and-configure/install-dashboards/helm/) Helm charts
    * Instal Fluent Bit using the [`fluent-operator`](https://github.com/fluent/fluent-operator) Helm chart and `FluentBit` CR
- [X] [PostgreSQL Database](https://www.postgresql.org/docs/current/) — SQL database used by Keycloak and other applications
    * Install on main RKE cluster using Bitnami's [`postgresql-ha`](https://github.com/bitnami/charts/tree/main/bitnami/postgresql-ha) Helm chart
- [X] [Keycloak IAM & OIDC Provider](https://www.keycloak.org/) — identity and access management and OpenID Connect provider
    * Install on main RKE cluster using the [`keycloakx`](https://github.com/codecentric/helm-charts/tree/master/charts/keycloakx) Helm chart
- [X] [Valkey Key/Value Store](https://valkey.io/) — Redis-compatible key/value store
    * Install on main RKE cluster using the [`valkey-cluster`](https://github.com/bitnami/charts/tree/main/bitnami/valkey-cluster) Helm chart
- [X] [Prometheus Monitoring Stack](https://github.com/prometheus-operator/kube-prometheus) — Prometheus (via Operator), Thanos sidecar, and Grafana
    * Install on main RKE cluster using the [`kube-prometheus-stack`](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack/) Helm chart
    * [X] Add authentication to Prometheus and Alertmanager UIs using [`oauth2-proxy`](https://github.com/oauth2-proxy/oauth2-proxy) sidecar
    * [X] Install other [Thanos components](https://thanos.io/tip/thanos/quick-tutorial.md/#querierquery) using Bitnami's [`thanos`](https://github.com/bitnami/charts/tree/main/bitnami/thanos/) Helm chart for global querying
    * [ ] Enable the [OTLP receiver](https://prometheus.io/docs/guides/opentelemetry/) endpoint for metrics _(when needed)_
- [X] [Istio Service Mesh](https://istio.io/latest/about/service-mesh/) with [Kiali Console](https://kiali.io/) — secure, observe, trace, and route traffic between workloads
    * Install on main RKE cluster using the [`istioctl`](https://istio.io/latest/docs/ambient/install/istioctl/) CLI
    * Install Kiali using the [`kiali-operator`](https://kiali.io/docs/installation/installation-guide/install-with-helm/#install-with-operator/) Helm chart and `Kiali` CR
- [X] [Argo CD Declarative GitOps](https://argo-cd.readthedocs.io/) — manage deployment of other applications in the main RKE cluster
    * Install on main RKE cluster using the [`argo-cd`](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd) Helm chart
- [X] [Kubernetes Metacontroller](https://metacontroller.github.io/metacontroller/) — enable easy creation of custom controllers
    * Install on main RKE cluster using the [`metacontroller`](https://metacontroller.github.io/metacontroller/guide/helm-install.html) Helm chart
- [X] [Ollama LLM Server](https://github.com/ollama/ollama) with [Ollama CLI](https://github.com/masgari/ollama-cli) — run LLMs on Kubernetes cluster
    * Install on an Intel GPU node using the [`ollama`](https://github.com/cowboysysop/charts/tree/master/charts/ollama) Helm chart and [IPEX-LLM Ollama portable zip](https://github.com/intel/ipex-llm/blob/main/docs/mddocs/Quickstart/ollama_portable_zip_quickstart.md)
- [ ] [Flowise Agentic Workflows](https://flowiseai.com/) — build AI agents using visual workflows
    * Install on main RKE cluster using the [`flowise`](https://github.com/cowboysysop/charts/tree/master/charts/flowise) Helm chart
- [ ] [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) with [Jaeger UI](https://www.jaegertracing.io/) -- telemetry collector agent and distributed tracing backend
    * Install on main RKE cluster using the [OpenTelemetry Collector](https://opentelemetry.io/docs/platforms/kubernetes/helm/collector/) Helm chart
    * Install Jaeger using the [Jaeger](https://github.com/jaegertracing/helm-charts/tree/main/charts/jaeger) Helm chart
- [ ] [Backstage Developer Portal](https://backstage.io/) — software catalog and developer portal
- [ ] [Meshery](https://github.com/meshery/meshery) — visual and collaborative GitOps platform
- [ ] [NATS](https://docs.nats.io/) — high performance message queues (Kafka alternative) with [JetStream](https://docs.nats.io/nats-concepts/jetstream) for persistence
- [ ] [KEDA](https://keda.sh/) — Kubernetes Event Driven Autoscaler

## To-Do Tasks

- [ ] Migrate manually provisioned certificates and secrets to ones issued by `cert-manager` with auto-rotation
- [ ] Automate creation of DNS records in pfSense via custom Ansible module that invokes pfSense REST APIs

## Ansible Vault

The Ansible Vault password is stored in macOS Keychain under item "`Home-K8s`" for account "`ansible-vault`".

```bash
export ANSIBLE_CONFIG="./ansible.cfg"
VAULTFILE="group_vars/all/vault.yml"

ansible-vault create $VAULTFILE
ansible-vault edit   $VAULTFILE
ansible-vault view   $VAULTFILE
```

<details>
<summary>Some variables stored in Ansible Vault <em>(there are many more)</em></summary><br/>

|      Infrastructure Secrets       |    User Passwords
|:---------------------------------:|:-------------------:
| `ansible_become_pass`             | `rancher_admin_pass`
| `github_access_token`             | `harbor_admin_pass`
| `age_secret_key`                  | `minio_root_pass`
| `icloud_smtp.*`                   | `minio_admin_pass`
| `k3s_token`                       | `opensearch_admin_pass`
| `rke2_token`                      | `keycloak_admin_pass`
| `stepca_provisioner_pass`         | `thanos_admin_pass`
| `minio_client_pass`               | `grafana_admin_pass`
| `velero_repo_pass`                | `argocd_admin_pass`
| `harbor_secret`                   |
| `dashboards_os_pass`              |
| `fluent_os_pass`                  |
| `valkey_pass`                     |
| `postgresql_pass`                 |
| `keycloak_db_pass`                |
| `keycloak_smtp_pass`              |
| `monitoring_pass`                 |
| `monitoring_oidc_client_secret.*` |
| `alertmanager_smtp_pass`          |
| `oauth2_proxy_cookie_secret`      |
| `kiali_oidc_client_secret`        |
| `argocd_signing_key`              |
</details>

## Connections

All managed hosts are running **Ubuntu 24.04** with SSH key from https://github.com/erhhung.keys already authorized.  

Ansible will authenticate as user `erhhung` using private key "`~/.ssh/erhhung.pem`";  
however, all privileged operations using `sudo` will require the password stored in Vault.

## Playbooks

1. <details><summary>Install required packages</summary><br/>

    1.1. **Tools** — `emacs`, `jq`, `yq`, `git`, and `helm`  
    1.2. **Python** — Pip packages in user **virtualenv**  
    1.3. **Helm** — Helm plugins: e.g. `helm-diff`

    ```bash
    ./play.sh packages
    ```
</details>

2. <details><summary>Configure system settings</summary><br/>

    2.1. **Host** — host name, time zone, and locale  
    2.2. **Kernel** — `sysctl` params and `pam_limits`  
    2.3. **Network** — DNS servers and search domains  
    2.4. **Login** — customize login MOTD messages  
    2.5. **Certs** — add CA certificates to trust store

    ```bash
    ./play.sh basics
    ```
</details>

3. <details><summary>Set up admin user's home directory</summary><br/>

    3.1. **Dot files**: `.bash_aliases`, etc.  
    3.2. **Config files**: `htop`, `fastfetch`

    ```bash
    ./play.sh files
    ```
</details>

4. <details><summary>Install <strong>Rancher Server</strong> on single-node <strong>K3s</strong> cluster</summary><br/>

    ```bash
    ./play.sh rancher
    ```
</details>

5. <details><summary>Provision <strong>Kubernetes cluster</strong> with <strong>RKE</strong> on 4 nodes</summary><br/>

    Install **RKE2** with a single control plane node and 3 worker nodes, all permitting workloads,  
    or RKE2 in HA mode with 3 control plane nodes and 1 worker node, all permitting workloads  
    _(in HA mode, the cluster will be accessible thru a **virtual IP** address courtesy of `kube-vip`)_

    ```bash
    ./play.sh cluster
    ```
</details>

6. <details><summary>Install <strong><code>cert-manager</code></strong> to automate certificate issuing</summary><br/>

    6.1. Connect to **Step CA** `pki.fourteeners.local` as a `ClusterIssuer`

    ```bash
    ./play.sh certmanager
    ```
</details>

7. <details><summary>Install <strong>Longhorn</strong> dynamic PV provisioner<br/> &nbsp; &nbsp; Install <strong>MinIO</strong> object storage in <em><strong>HA</strong></em> mode<br/> &nbsp; &nbsp; Install <strong>Velero</strong> backup and restore tools</summary><br/>

    7.1. Create a pool of LVM logical volumes  
    7.2. Install Longhorn storage components  
    7.3. Install NFS dynamic PV provisioner  
    7.4. Install MinIO tenant using NFS PVs  
    7.5. Install Velero using MinIO as target

    ```bash
    ./play.sh storage minio velero
    ```
</details>

8. <details><summary>Install <strong>Harbor</strong> OCI & Helm registry</summary><br/>

    ```bash
    ./play.sh harbor
    ```
</details>

9. <details><summary>Create resources from manifest files</summary><br/>

    **IMPORTANT**: Resource manifests must specify the namespaces they wished to be installed  
    into because the playbook simply applies each one without targeting a specific namespace

    ```bash
    ./play.sh manifests
    ```
</details>

10. <details><summary>Install <strong>Node Feature Discovery</strong> to identify GPU nodes</summary><br/>

    10.1. Install Intel Device Plugins and `GpuDevicePlugin`

    ```bash
    ./play.sh nodefeatures
    ```
</details>

11. <details><summary>Install <strong>OpenSearch</strong> cluster in <em><strong>HA</strong></em> mode</summary><br/>

    11.1. Configure the OpenSearch security plugin (users and roles) for downstream applications  
    11.2. Install **OpenSearch Dashboards** UI

    ```bash
    ./play.sh opensearch
    ```
</details>

12. <details><summary>Install <strong>Fluent Bit</strong> to ingest logs into OpenSearch</summary><br/>

    ```bash
    ./play.sh logging
    ```
</details>

13. <details><summary>Install <strong>PostgreSQL</strong> database in <em><strong>HA</strong></em> mode</summary><br/>

    13.1. Run initialization SQL script to create roles and databases for downstream applications  
    13.2. Create users in both PostgreSQL and **Pgpool**

    ```bash
    ./play.sh postgresql
    ```
</details>

14. <details><summary>Install <strong>Keycloak</strong> IAM & OIDC provider</summary><br/>

    14.1. Bootstrap **PostgreSQL** database with realm `homelab`, user `erhhung`, and OIDC clients

    ```bash
    ./play.sh keycloak
    ```
</details>

15. <details><summary>Install <strong>Valkey</strong> key-value store in <em><strong>HA</strong></em> mode</summary><br/>

    15.1. Deploy 6 nodes in total: 3 primaries and 3 replicas

    ```bash
    ./play.sh valkey
    ```
</details>

16. <details><summary>Install <strong>Prometheus</strong>, <strong>Thanos</strong>, and <strong>Grafana</strong> in <em><strong>HA</strong></em> mode</summary><br/>

    16.1. Expose Prometheus & Alertmanager UIs via `oauth2-proxy` integration with **Keycloak**  
    16.2. Connect Thanos sidecars to **MinIO** to store scraped metrics in the `metrics` bucket  
    16.3. Deploy and integrate other Thanos components with Prometheus and Alertmanager

    ```bash
    ./play.sh monitoring thanos
    ```
</details>

17. <details><summary>Install <strong>Istio</strong> service mesh in <em><strong>ambient</strong></em> mode</summary><br/>

    ```bash
    ./play.sh istio
    ```
</details>

18. <details><summary>Install <strong>Argo CD</strong> GitOps delivery in <em><strong>HA</strong></em> mode</summary><br/>

    18.1. Configure Argo CD components to use the **Valkey** cluster for their caching needs

    ```bash
    ./play.sh argocd
    ```
</details>

19. <details><summary>Install <strong>Metacontroller</strong> to create Operators</summary><br/>

    ```bash
    ./play.sh metacontroller
    ```
</details>

20. <details><summary>Install <strong>Ollama</strong> LLM server with models</summary><br/>

    ```bash
    ./play.sh ollama
    ```
</details>

21. <details><summary>Create <strong>virtual clusters</strong> in RKE running <strong>K0s</strong></summary><br/>

    ```bash
    ./play.sh vclusters
    ```
</details>

Alternatively, **run all playbooks** automatically in order:

```bash
# pass options like -v and --step
./play.sh [ansible-playbook-opts]

# run all playbooks starting from "storage"
# ("storage" is a playbook tag in main.yml)
./play.sh storage-
```

Output from `play.sh` will be logged in "`ansible.log`".

### VS Code Shortcuts

The default Bash shell for VS Code terminal has been configured to load a custom [`.bash_profile`](.vscode/.bash_profile) containing aliases for common Ansible commands as well as the `play` function with **completions** for playbook tags.

### Multipass Required

Due to the dependency chain of the **Prometheus monitoring stack** (Keycloak and Valkey), the `monitoring.yml` playbook must be run after most other playbooks. At the same time, those dependent services also want to create `ServiceMonitor` resources that require the Prometheus Operator CRDs. Therefore, a **second pass** through all playbooks, starting with `certmanager.yml`, is required to **enable metrics collection** on those services.

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

## VM Storage

To expand the VM disk on a cluster node, the VM must be shut down
(attempting to resize the disk from Xen Orchestra will fail with
error: `VDI in use`).

<details>
<summary>Once the VM disk has been expanded, restart the VM and SSH into
the node to resize the partition and LV.</summary><br/>

```bash
$ sudo su

# verify new size
$ lsblk /dev/xvda

# resize partition
$ parted /dev/xvda
) print
Warning: Not all of the space available to /dev/xvda appears to be used...
Fix/Ignore? Fix

) resizepart 3 100%
# confirm new size
) print
) quit

# sync with kernel
$ partprobe

# confirm new size
$ lsblk /dev/xvda3

# resize VG volume
$ pvresize /dev/xvda3
Physical volume "/dev/xvda3" changed
1 physical volume(s) resized...

# confirm new size
$ pvdisplay

# show LV volumes
$ lvdisplay

# set exact LV size (G=GiB)
$ lvextend -vrL 50G /dev/ubuntu-vg/ubuntu-lv
# or grow LV by percentage
$ lvextend -vrl +90%FREE /dev/ubuntu-vg/ubuntu-lv
Extending logical volume ubuntu-vg/ubuntu-lv to up to...
fsadm: Executing resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
The filesystem on /dev/mapper/ubuntu--vg-ubuntu--lv is now...
```
</details>

<details>
<summary>After expanding all desired disks, run <code>./diskfree.sh</code>
to confirm available disk space on all cluster nodes.</summary><br/>

```bash
rancher
-------
Filesystem      Size  Used Avail Use% Mounted on
/dev/xvda2       32G   18G   13G  60% /

k8s1
----
Filesystem                         Size  Used Avail Use% Mounted on
/dev/mapper/ubuntu--vg-ubuntu--lv   50G   21G   27G  44% /
/dev/mapper/ubuntu--vg-data--lv     30G  781M   30G   3% /data

k8s2
----
Filesystem                         Size  Used Avail Use% Mounted on
/dev/mapper/ubuntu--vg-ubuntu--lv   50G   22G   26G  47% /
/dev/mapper/ubuntu--vg-data--lv     30G  781M   30G   3% /data

k8s3
----
Filesystem                         Size  Used Avail Use% Mounted on
/dev/mapper/ubuntu--vg-ubuntu--lv   50G   23G   25G  48% /
/dev/mapper/ubuntu--vg-data--lv     30G  1.2G   29G   4% /data

k8s4
----
Filesystem                         Size  Used Avail Use% Mounted on
/dev/mapper/ubuntu--vg-ubuntu--lv   50G   27G   21G  57% /
/dev/mapper/ubuntu--vg-data--lv     30G  1.2G   29G   4% /data
```
</details>

## Troubleshooting

Ansible's [ad-hoc commands](https://docs.ansible.com/ansible/latest/command_guide/intro_adhoc.html#managing-services) are useful in these scenarios.

1. Restart Kubernetes cluster services on all nodes

    ```bash
    ansible rancher          -m ansible.builtin.service -b -a "name=k3s         state=restarted"
    ansible control_plane_ha -m ansible.builtin.service -b -a "name=rke2-server state=restarted"
    ansible workers_ha       -m ansible.builtin.service -b -a "name=rke2-agent  state=restarted"
    ```

    _**NOTE:** remove `_ha` suffix from target hosts if the RKE cluster was deployed in non-HA mode._

2. All `kube-proxy` static pods on continuous `CrashLoopBackOff`

    This turns out to be a [Linux kernel bug](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2104282) in `linux-image-6.8.0-56-generic` and above _(discovered on upgrade to `linux-image-6.8.0-57-generic`)_, causing this error in the container logs:

    ```
    ip6tables-restore v1.8.9 (nf_tables): unknown option "--xor-mark"
    ```

    <details><summary>Current workaround is to downgrade to an earlier kernel.</summary><br/>

    ```bash
    # list installed kernel images
    ansible -v k8s_all -a 'bash -c "dpkg -l | grep linux-image"'

    # install working kernel image
    ansible -v k8s_all -b -a 'apt-get install -y linux-image-6.8.0-55-generic'

    # GRUB use working kernel image
    ansible -v rancher -m ansible.builtin.shell -b -a '
        kernel="6.8.0-55-generic"
        dvuuid=$(blkid -s UUID -o value /dev/xvda2)
        menuid="gnulinux-advanced-$dvuuid>gnulinux-$kernel-advanced-$dvuuid"
        sed -Ei "s/^(GRUB_DEFAULT=).+$/\\1\"$menuid\"/" /etc/default/grub
        grep GRUB_DEFAULT /etc/default/grub
    '
    ansible -v cluster -m ansible.builtin.shell -b -a '
        kernel="6.8.0-55-generic"
        dvuuid=$(blkid -s UUID -o value /dev/mapper/ubuntu--vg-ubuntu--lv)
        menuid="gnulinux-advanced-$dvuuid>gnulinux-$kernel-advanced-$dvuuid"
        sed -Ei "s/^(GRUB_DEFAULT=).+$/\\1\"$menuid\"/" /etc/default/grub
        grep GRUB_DEFAULT /etc/default/grub
    '
    # update /boot/grub/grub.cfg
    ansible -v k8s_all -b -a 'update-grub'

    # reboot nodes, one at a time
    ansible -v k8s_all -m ansible.builtin.reboot -b -a "post_reboot_delay=120" -f 1

    # confirm working kernel image
    ansible -v k8s_all -a 'uname -r'

    # remove old backup kernels only
    # (keep latest non-working kernel
    # so upgrade won't install again)
    ansible -v k8s_all -b -a 'apt-get autoremove -y --purge'
    ```
    </details>
