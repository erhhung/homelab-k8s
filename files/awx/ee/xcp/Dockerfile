FROM ghcr.io/erhhung/al2023-devops:latest

SHELL ["/bin/bash", "-c"]

ARG PYPROJECT_URL="https://raw.githubusercontent.com/erhhung/homelab-xcp/refs/heads/main/pyproject.toml"

ENV UV_PROJECT_ENVIRONMENT="/runner/.venv"
ENV VIRTUAL_ENV="$UV_PROJECT_ENVIRONMENT"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

WORKDIR /runner/project

RUN <<'EOT'
( set -eux

# download custom Ansible requirements file
curl -fsSLo pyproject.toml "$PYPROJECT_URL"
uv sync && rm -f pyproject.toml uv.lock

# make sure Pip uses virtualenv
python3 -m ensurepip --upgrade
ln -s pip3 $VIRTUAL_ENV/bin/pip

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
