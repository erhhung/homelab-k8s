# Repository Guide

## Safety

- This repository provisions the live `homelab` infrastructure. Ordinary playbook targets such as `make monitoring` mutate remote hosts and Kubernetes resources; do not run them as validation unless deployment is explicitly requested.
- Do not target Ansible's `all` group: it includes the non-Ubuntu XCP-ng host. Use the inventory groups in `inventory/hosts.ini`.
- Secrets live in Ansible Vault files. `ansible.cfg` calls `scripts/vaultpass.sh`, which requires macOS Keychain, an `AGE_KEY_FILE`, or the `.vaultpass` file in AWX. Never replace encrypted files with decrypted content or commit `.env`, `ansible.log`, `temp.yml`, or `.ansible/facts/`.

## Execution Model

- `main.yml` is the dependency-ordered deployment graph. Keep its initial localhost play and `# ======= DO NOT REMOVE =======`; it establishes `project_dir` for all later imports.
- `make <tag> [<tag>...]` selects top-level tags from `main.yml`, always runs them in `main.yml` order, and does not add their dependencies. Check the dependency comments in `main.yml` before selecting a subset.
- A lone `tag-` runs from that tag to the end; a lone `-tag` runs from the beginning through that tag. Pass Ansible options after `--`, for example `make monitoring -- --check` or `make openwebui -- -t knowledge`. Range selectors cannot be combined with other tags.
- Running every playbook requires a second pass from `certmanager` after `monitoring` has installed Prometheus Operator CRDs; otherwise earlier services cannot create their `ServiceMonitor` resources.
- `scripts/play.sh` exports the repository Ansible config and `$HOME/.ssh/$USER.pem`, writes colorless output to `ansible.log`, and clears cached facts only for a full run. It installs Galaxy dependencies automatically only when `cluster` is selected.

## Layout

- `playbooks/` contains service orchestration; `vars/` contains service and Helm chart configuration; reusable includes belong in `tasks/`; rendered resources and payloads belong in `templates/` and `files/`.
- Most charts are deployed through `tasks/helm/helmfile.yml`, which combines Helmfile, Kustomize patches, and adoption of pre-created resources. Preserve its input conventions instead of adding direct Helm invocations to individual playbooks.
- `manifests/all/`, `manifests/k3s/`, and `manifests/rke/` are applied in sorted filename order. Only non-hidden `*.yaml` files are loaded, and every resource must declare its own namespace.
- `tests/bazel/` is an integration fixture for the deployed Buildfarm and BuildBuddy endpoints, not a general repository test suite.

## Setup And Verification

- Use Python 3.13+ and install locked Python dependencies with `uv sync`; keep `pyproject.toml` and `requirements.txt` synchronized when dependencies change. Install Ansible content with `ansible-galaxy install -r requirements.yml`.
- The Makefile requires GNU Make 4+; its runlist generation also requires `yq` and `jo` on `PATH`.
- List valid deployment selectors with `make tags`.
- Run syntax validation with `make check`. Run all lint checks with `make lint`, or lint selected playbooks with `make lint monitoring` (multiple names are allowed).
- For custom Python plugins, add a focused local check where practical; they are loaded from `plugins/filter/` and `plugins/lookup/` by `ansible.cfg` and have no standalone test suite.
