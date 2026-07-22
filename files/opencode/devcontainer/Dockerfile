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

RUN --mount=type=bind,readonly,source=install,target=/install \
    --mount=type=bind,readonly,source=config,target=/config \
<<EOF
dnf install -y --allowerasing sudo gnupg2 openssh-server
dnf clean all
rm -rf /var/log/* /var/cache/dnf

# restore binary login-accounting files:
# https://linuxhandbook.com/utmp-wtmp-btmp
touch /var/log/{btmp,wtmp,lastlog}
chmod  664 /var/log/{wtmp,lastlog}
chmod  600 /var/log/btmp

# install VSCode wrapper script
cp /install/code /usr/local/bin
# install helpful dev utilities
for install in /install/*.sh; do $install; done

# https://opencode.ai/docs#install
# https://github.com/carloscuesta/gitmoji-cli
pnpm --config.updateNotifier=false install \
  -g --allow-build=opencode-ai gitmoji-cli \
                   opencode-ai

# copy dot files into /root to be inherited by dev user
tail -n+2 /config/.bash_profile >> /root/.bash_profile
cp /config/{.dircolors,.lessopen}  /root

# create dev user using /root as template
groupadd --gid "${DEV_GID}" "${DEV_GROUP}"
 useradd --uid "${DEV_UID}" --gid "${DEV_GID}" "${DEV_USER}" \
         --create-home --skel /root --shell /bin/bash

# enable passwordless sudo for dev user
echo "${DEV_USER} ALL=(ALL) NOPASSWD:ALL" \
        > /etc/sudoers.d/${DEV_USER}
chmod 440 /etc/sudoers.d/${DEV_USER}

# propagate environment vars to dev user
cat <(env | grep -vE '^(USER|HOME|PWD|OLDPWD|SHLVL|_)' \
          | sed  's|/root/|$HOME/|g')   \
    <(grep -vE '^#' /config/etc_profile \
          | sed  '/^[[:space:]]*$/d') \
          | sort | sed 's/^/export /' \
    > /etc/profile.d/user.sh

# copy dot files directly into dev user`s home directory
tail -n+2 /config/.gitconfig >> /home/${DEV_USER}/.gitconfig

# suppress login banner by masking /usr/lib/motd.d/30-banner with
# empty /etc/motd.d/30-banner  because pam_motd (/etc/pam.d/sshd)
# gives /etc/motd.d precedence over /usr/lib/motd.d
ln -sf /dev/null /etc/motd.d/30-banner

# install custom sshd_config file
mkdir -p /etc/ssh/{host_keys,authorized_keys}
SSH_PORT="${SSH_PORT}" DEV_USER="${DEV_USER}"
envsubst < /config/sshd_config > /etc/ssh/sshd_config.d/10-devcontainer.conf
EOF

EXPOSE ${SSH_PORT}

# -D: run in foreground for monitoring
# -e: output error messages to stderr
CMD ["/usr/sbin/sshd", "-D", "-e"]
