# `skopeo list-tags docker://mirror.gcr.io/aquasec/trivy`
ARG TRIVY_IMAGE_TAG="latest"
FROM mirror.gcr.io/aquasec/trivy:${TRIVY_IMAGE_TAG}

# hardcode environment variables required by scan job containers
# because Trivy Operator doesn't expose a method to inject them:
# https://github.com/aquasecurity/trivy-operator/issues/2971
ENV CONTAINERD_ADDRESS=/run/k3s/containerd/containerd.sock
ENV CONTAINERD_NAMESPACE=k8s.io
