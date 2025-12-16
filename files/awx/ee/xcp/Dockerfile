# this container image installs a downgraded version of Ansible
# that is compatible with Python 3.6.8 installed on XCP-ng 8.3

# https://github.com/erhhung/al2023-devops
FROM ghcr.io/erhhung/al2023-devops:latest

ARG PYPROJECT_URL="https://raw.githubusercontent.com/erhhung/homelab-xcp/refs/heads/main/pyproject.toml"

ENV UV_PROJECT_ENVIRONMENT="/runner/.venv"
ENV VIRTUAL_ENV="$UV_PROJECT_ENVIRONMENT"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

RUN <<'EOT'
( set -eux

# download custom Ansible requirements file
curl -fsSLo pyproject.toml "$PYPROJECT_URL"
uv sync --no-cache --no-dev
rm -f pyproject.toml uv.lock

# make sure Pip uses virtualenv
python3 -m ensurepip --upgrade
ln -s pip3 $VIRTUAL_ENV/bin/pip
pip3 install --no-cache-dir ansible-runner

# update Ansible version in manifest
OUT="/root/.versions.json"
# <component> <version>
setver() {
  echo >&2 "$1: $2"
  jo -- -s "$1"="$2" | jq -sSM '.[0]*.[1]' $OUT - | sponge $OUT
}
setver ansible $(v=(`ansible --version | head -1`); echo ${v[-1]%\]})
)
EOT

SHELL ["/bin/bash", "-c"]
WORKDIR /runner/project
