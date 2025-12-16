# this container image is intended to run quick
# Ansible tasks like workflow setup and teardown

FROM alpine:latest

ENV VIRTUAL_ENV="/runner/.venv"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

RUN <<'EOT'
( set -eux

apk add --no-cache bash perl curl ca-certificates \
                   openssl yq jq jo python3 py3-pip

python3 -m venv $VIRTUAL_ENV
. $VIRTUAL_ENV/bin/activate

args="--no-cache-dir --root-user-action=ignore --upgrade"
pip3 install $args pip
pip3 install $args ansible-core ansible-runner \
  jmespath toml netaddr passlib bcrypt==4.0.1
ansible-galaxy collection install --no-cache \
  ansible.utils ansible.posix community.general

ansible-playbook --version
ansible-runner   --version
)
EOT

SHELL ["/bin/bash", "-c"]
WORKDIR /runner/project
