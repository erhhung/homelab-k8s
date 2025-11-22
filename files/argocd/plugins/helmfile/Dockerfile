FROM ubuntu:24.04

SHELL ["/bin/bash", "-c"]

ARG HELM_VERSION="4.0.0"
ARG HELMFILE_VERSION="1.2.0"
ARG HELM_SECRETS_VERSION="4.7.1"
ARG VALS_VERSION="0.42.4"

# create argocd user
RUN <<'EOT'
( set -eux

groupadd -g 999    argocd
 useradd -u 999 -g argocd -m argocd
)
EOT

# install basic utils
RUN <<'EOT'
( set -eux

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --no-install-recommends -y git curl ca-certificates
apt-get clean
rm -rf /var/lib/apt/lists/*
)
EOT

# install jq/yq/sops/age
RUN <<'EOT'
( set -euxo pipefail

ARCH=$(uname -m | sed -e 's/aarch64/arm64/' -e 's/x86_64/amd64/')

install_bin() {
  cd /usr/local/bin
  local bin=$1 src=$2
  curl -fsSLo $bin $src
  chmod +x $bin
  $bin --version
}

# install jq: https://stedolan.github.io/jq
install_bin jq "https://github.com/stedolan/jq/releases/latest/download/jq-linux-$ARCH"
# install yq: https://github.com/mikefarah/yq
install_bin yq "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$ARCH"

# install sops: https://github.com/getsops/sops
REL="https://github.com/getsops/sops/releases"
VER=$(curl -Is "$REL/latest" | sed -En 's/^location:.+\/tag\/v(.+)\r$/\1/p')
(
  export SOPS_DISABLE_VERSION_CHECK=1
  install_bin sops "$REL/download/v${VER}/sops-v${VER}.linux.$ARCH"
)

# install age: https://github.com/FiloSottile/age#installation
REL="https://github.com/FiloSottile/age/releases"
VER=$(curl -Is "$REL/latest" | sed -En 's/^location:.+\/tag\/v(.+)\r$/\1/p')
curl -fsSL "$REL/download/v${VER}/age-v${VER}-linux-$ARCH.tar.gz" | \
  tar -xz -C /usr/local/bin --no-same-owner --strip 1 --wildcards 'age/age*'
age --version
)
EOT

# trust private CA certs
RUN <<'EOT'
( set -euxo pipefail

# https://github.com/smallstep/certificates/tree/master/api/api.go#L328-L342
curl -sk https://pki.fourteeners.local/roots | jq -r '.crts[]' \
  > /usr/local/share/ca-certificates/fourteeners-local.crt
update-ca-certificates
)
EOT

# create Git credential
# store read-only script
RUN <<'EOT'
( set -eux

gcs_sh="/usr/local/bin/git-credential-store-ro"
cat <<'EOF' > $gcs_sh
#!/bin/sh

[ "$1" = get ] || exit 0 # ignore store & erase
exec /usr/lib/git-core/git-credential-store "$@"
EOF
chmod +x $gcs_sh
)
EOT

# install Helmfile/Kustomize/vals
RUN <<'EOT'
( set -euxo pipefail

ARCH=$(uname -m | sed -e 's/aarch64/arm64/' -e 's/x86_64/amd64/')

# install Helm: https://helm.sh/docs/intro/install/
VER="$HELM_VERSION"
curl -fsSL "https://get.helm.sh/helm-v${VER}-linux-$ARCH.tar.gz" | \
  tar -xz -C /usr/local/bin --no-same-owner --strip 1 "linux-$ARCH"/helm
helm version

# install Helmfile: https://github.com/helmfile/helmfile#installation
REL="https://github.com/helmfile/helmfile/releases"
VER="$HELMFILE_VERSION"
curl -fsSL "$REL/download/v${VER}/helmfile_${VER}_linux_${ARCH}.tar.gz" | \
  tar -xz -C /usr/local/bin --no-same-owner helmfile
helmfile --version

# install Kustomize: https://kubectl.docs.kubernetes.io/installation/kustomize/binaries
REL="https://github.com/kubernetes-sigs/kustomize/releases"
VER=$(curl -Is "$REL/latest" | sed -En 's/^location:.+\/tag\/kustomize\/v(.+)\r$/\1/p')
curl -fsSL "$REL/download/kustomize/v${VER}/kustomize_v${VER}_linux_${ARCH}.tar.gz" | \
  tar -xz -C /usr/local/bin --no-same-owner kustomize
kustomize version

# install vals: https://github.com/helmfile/vals#installation
REL="https://github.com/helmfile/vals/releases"
VER="$VALS_VERSION"
curl -fsSL "$REL/download/v${VER}/vals_${VER}_linux_${ARCH}.tar.gz" | \
  tar -xz -C /usr/local/bin --no-same-owner vals
vals version
)
EOT

COPY --link *.sh /usr/local/bin/
USER argocd

# HELM_BIN is required by helm-git
ENV HELM_BIN="/usr/local/bin/helm"
ENV HELM_PLUGINS="/home/argocd/.local/share/helm/plugins"

# install Helm plugins
RUN <<'EOT'
( set -exo pipefail

install_plugin() {
  local repo=$1 ver=$2 tgz=$3
  [ "$ver" ] || ver=$(
    curl -Is "$repo/releases/latest" | sed -En 's/^location:.+\/tag\/v(.+)\r$/\1/p'
  )
  local args=(--verify=false)
  if [ "$tgz" ]; then
    args+=("$repo/releases/download/v${ver}/${tgz//=VER=/$ver}")
  else
    args+=($repo --version $ver)
  fi
  helm plugin install "${args[@]}"
}

install_plugin https://github.com/aslafy-z/helm-git
# apply patch to fix invalid `helm version` command
sed -Ei 's/version -c/version/' $HELM_PLUGINS/helm-git/helm-git-plugin.sh

install_plugin https://github.com/databus23/helm-diff

# https://github.com/jkroepke/helm-secrets/wiki/Installation
install_plugin https://github.com/jkroepke/helm-secrets $HELM_SECRETS_VERSION secrets-=VER=.tgz
install_plugin https://github.com/jkroepke/helm-secrets $HELM_SECRETS_VERSION secrets-getter-=VER=.tgz
install_plugin https://github.com/jkroepke/helm-secrets $HELM_SECRETS_VERSION secrets-post-renderer-=VER=.tgz

helm plugin list
)
EOT

# create ~/.gitconfig
RUN <<'EOT'
( set -eux

# use read-only git-credential-store script
# that ignores `store` and `erase` commands
git config --add --global credential.helper \
  /usr/local/bin/git-credential-store-ro

# this stub file should be
# shadow mounted by Secret
touch     ~/.git-credentials
chmod 400 ~/.git-credentials
)
EOT

WORKDIR /home/argocd/cmp-server/
# USER does NOT affect COPY permissions: use --chown
COPY --chown=argocd:argocd --link plugin.yaml ./config/
