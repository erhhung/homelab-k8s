# this container image installs OpenSSH and OpenCode servers
# for remote development using VS Code remote SSH connection

# https://github.com/erhhung/al2023-devops
FROM ghcr.io/erhhung/al2023-devops:latest

ARG DEV_USER="vscode"
ARG DEV_UID="1000"
ARG DEV_GROUP="vscode"
ARG DEV_GID="1000"
ARG SSH_PORT="22"

USER root

RUN --mount=type=bind,source=profile.sh,target=/tmp/profile.sh \
  dnf install -y sudo openssh-server \
  && dnf clean all \
  && rm -rf /var/log/* /var/cache/dnf \
  \
  # https://opencode.ai/docs#install
  && pnpm --config.updateNotifier=false install \
       -g --allow-build=opencode-ai opencode-ai \
  \
  # create non-root user for remote SSH
  && groupadd --gid "${DEV_GID}" "${DEV_GROUP}" \
  &&  useradd --uid "${DEV_UID}" --gid "${DEV_GID}" \
      --create-home --skel /root --shell /bin/bash "${DEV_USER}" \
  \
  # enable passwordless sudo for dev user
  && echo "${DEV_USER} ALL=(ALL) NOPASSWD:ALL" \
             > /etc/sudoers.d/${DEV_USER} \
  && chmod 440 /etc/sudoers.d/${DEV_USER} \
  \
  # propagate environment vars to dev user
  && cat <(env | grep -vE '^(USER|HOME|PWD|OLDPWD|SHLVL|_)' \
               | sed 's|/root/|$HOME/|g')  \
         <(grep -vE '^#' /tmp/profile.sh   \
               | sed  '/^[[:space:]]*$/d') \
               | sort | sed 's/^/export /' \
   > /etc/profile.d/user.sh

# install custom sshd_config file
RUN --mount=type=bind,source=sshd_config,target=/tmp/sshd_config \
  SSH_PORT="${SSH_PORT}" \
  DEV_USER="${DEV_USER}" \
  envsubst < /tmp/sshd_config > /etc/ssh/sshd_config.d/10-devcontainer.conf \
  \
  && mkdir -p /etc/ssh/host_keys /etc/ssh/authorized_keys \
  \
  # suppress login banner by masking /usr/lib/motd.d/30-banner with
  # empty /etc/motd.d/30-banner  because pam_motd (/etc/pam.d/sshd)
  # gives /etc/motd.d precedence over /usr/lib/motd.d
  && ln -sf /dev/null /etc/motd.d/30-banner

EXPOSE ${SSH_PORT}

# -D: run in foreground for monitoring
# -e: output error messages to stderr
CMD ["/usr/sbin/sshd", "-D", "-e"]
