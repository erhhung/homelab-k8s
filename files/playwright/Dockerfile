ARG PLAYWRIGHT_IMAGE_TAG="latest"
FROM mcr.microsoft.com/playwright:${PLAYWRIGHT_IMAGE_TAG}

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      # Intel Vulkan driver
      # enable WebGL on GPU
      mesa-vulkan-drivers \
      vulkan-tools \
      # create NSS database
      libnss3-tools \
 && rm -rf /var/lib/apt/lists/* \
 # create directory for $XDG_RUNTIME_DIR
 && install -o ubuntu -g ubuntu -m 700 \
            -d /run/user/$(id -u ubuntu)

USER ubuntu
