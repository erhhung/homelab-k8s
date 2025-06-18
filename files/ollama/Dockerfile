FROM ubuntu:24.04

SHELL ["/bin/bash", "-c"]

# https://dgpu-docs.intel.com/driver/client/overview.html
RUN <<'EOT'
( set -uxo pipefail

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install --no-install-recommends -y software-properties-common curl
  add-apt-repository -y ppa:kobuk-team/intel-graphics
  apt-get update
  apt-get install --no-install-recommends -y libze-intel-gpu1 libze1 \
    intel-metrics-discovery intel-gsc intel-opencl-icd clinfo
  apt-get clean
  rm -rf /var/lib/apt/lists/*
)
EOT

RUN <<'EOT'
( set -uxo pipefail

  userdel -rf ubuntu
  groupadd -g 993  render
  groupadd -g 1000 ollama
  useradd -m -b /opt -u 1000 -g 1000 -G render -s /bin/bash ollama
)
EOT

USER ollama
WORKDIR /opt/ollama

# https://github.com/intel/ipex-llm/tree/main/docs/mddocs/Quickstart/ollama_portable_zip_quickstart.md
RUN <<'EOT'
( set -uxo pipefail

  mkdir ollama-ipex-llm
  REL="https://github.com/ipex-llm/ipex-llm/releases/latest"
  VER=$(curl -Is $REL | sed -En 's/^location:.+\/tag\/v(.+)\r$/\1/p')
  curl -fsSL "$REL/download/ollama-ipex-llm-$VER-ubuntu.tgz" | \
    tar -xz -C ollama-ipex-llm --no-same-owner --strip-components=1
)
EOT

# run Gin in production mode
ENV GIN_MODE=release
# enable Intel GPU detection
ENV OLLAMA_INTEL_GPU=1
# force all layers to use GPU
ENV OLLAMA_NUM_GPU=999
# force Ollama to use one GPU
ENV ONEAPI_DEVICE_SELECTOR=level_zero:0
# per IPEX-LLM recommendation
ENV SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS=1
# per llama.cpp recommendation
ENV SYCL_CACHE_PERSISTENT=1
# support ext_intel_free_memory
ENV ZES_ENABLE_SYSMAN=1

ENV PATH="$PATH:/opt/ollama/ollama-ipex-llm"
WORKDIR /opt/ollama/ollama-ipex-llm

# don't run start-ollama.sh because it hardcodes
# environment variables that we want to override
CMD ["ollama", "serve"]
