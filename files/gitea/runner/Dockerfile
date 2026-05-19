# https://gitea.com/gitea/runner/releases
ARG RUNNER_IMAGE_TAG="latest"
FROM docker.gitea.com/runner:${RUNNER_IMAGE_TAG} AS upstream

# https://github.com/erhhung/al2023-devops
FROM ghcr.io/erhhung/al2023-devops:latest

COPY --from=upstream /usr/local/bin/gitea-runner /usr/local/bin/gitea-runner
COPY --from=upstream /usr/local/bin/run.sh       /usr/local/bin/entrypoint.sh

RUN <<'EOF'
# patch entrypoint script
sed -i -e '/^# Prevent reading/i\
'      -e '/^# In case no token/i\
# Add our private CA certificate to the system trust store\
if compgen -G "/etc/pki/ca-trust/source/anchors/*.crt" > /dev/null; then\
  update-ca-trust && head -n 13 /etc/pki/tls/certs/ca-bundle.crt\
fi\
' /usr/local/bin/entrypoint.sh
EOF

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
