# ============================================
# llama-openvino-docker — OpenVINO Docker (Ubuntu 24.04)
# 严格参照:
#   https://github.com/ggml-org/llama.cpp/.devops/openvino.Dockerfile
# ============================================
#
# 构建:
#   docker build --target=base -t llama-openvino:base .
#   docker build --target=full -t llama-openvino:full .
#   docker build --target=light -t llama-openvino:light .
#   docker build --target=server -t llama-openvino:server .
#
# 运行 (CPU):
#   docker run --rm -it -v ~/models:/models llama-openvino:light \
#       --no-warmup -c 1024 -m /models/model.gguf
#
# 运行 (Intel GPU):
#   docker run --rm -it -v ~/models:/models \
#       --device=/dev/dri \
#       --group-add=$(stat -c "%g" /dev/dri/render* | head -n 1) \
#       -u $(id -u):$(id -g) \
#       --env=GGML_OPENVINO_DEVICE=GPU \
#       llama-openvino:light \
#       --no-warmup -c 1024 -m /models/model.gguf

ARG OPENVINO_VERSION_MAJOR=2026.2
ARG OPENVINO_VERSION_FULL=2026.2.0.21903.52ddc073857
ARG UBUNTU_VERSION=24.04

ARG IGC_VERSION=v2.36.3
ARG IGC_VERSION_FULL=2_2.36.3+21719
ARG COMPUTE_RUNTIME_VERSION=26.22.38646.4
ARG COMPUTE_RUNTIME_VERSION_FULL=26.22.38646.4-0
ARG IGDGMM_VERSION=22.10.0

ARG BUILD_DATE=N/A
ARG APP_VERSION=N/A
ARG APP_REVISION=N/A

# ============================================
# Build Stage
# ============================================
FROM docker.io/ubuntu:${UBUNTU_VERSION} AS build

ARG OPENVINO_VERSION_MAJOR
ARG OPENVINO_VERSION_FULL
ARG http_proxy
ARG https_proxy

# 安装编译依赖
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        libcurl4-openssl-dev \
        libtbb12 \
        cmake \
        ninja-build \
        ca-certificates \
        gnupg \
        wget \
        curl \
        git \
        ocl-icd-opencl-dev \
        opencl-headers \
        opencl-clhpp-headers \
        intel-opencl-icd && \
    rm -rf /var/lib/apt/lists/*

# 下载并安装 OpenVINO Runtime（Intel 官方归档）
RUN mkdir -p /opt/intel && \
    TGZ="/tmp/openvino.tgz" && \
    wget -O "$TGZ" "https://storage.openvinotoolkit.org/repositories/openvino/packages/${OPENVINO_VERSION_MAJOR}/linux/openvino_toolkit_ubuntu24_${OPENVINO_VERSION_FULL}_x86_64.tgz" && \
    tar -xzf "$TGZ" -C /opt/intel/ && \
    mv "/opt/intel/openvino_toolkit_ubuntu24_${OPENVINO_VERSION_FULL}_x86_64" "/opt/intel/openvino_${OPENVINO_VERSION_MAJOR}" && \
    cd "/opt/intel/openvino_${OPENVINO_VERSION_MAJOR}" && \
    echo "Y" | ./install_dependencies/install_openvino_dependencies.sh && \
    cd / && \
    ln -s "/opt/intel/openvino_${OPENVINO_VERSION_MAJOR}" /opt/intel/openvino && \
    rm -f "$TGZ"

ENV OpenVINO_DIR=/opt/intel/openvino

WORKDIR /app

# 克隆 llama.cpp 源码（含子模块）
RUN git clone --depth=1 --recursive https://github.com/ggml-org/llama.cpp.git .

# 构建
RUN bash -c "source ${OpenVINO_DIR}/setupvars.sh && \
    cmake -B build/ReleaseOV -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_BUILD_TESTS=OFF \
        -DGGML_OPENVINO=ON && \
    cmake --build build/ReleaseOV --parallel"

# 收集共享库（build 产物 + OpenVINO 运行时）
RUN mkdir -p /app/lib && \
    find build/ReleaseOV -name '*.so*' -exec cp -P {} /app/lib \; && \
    find "${OpenVINO_DIR}/runtime/lib/intel64" -name '*.so*' -exec cp -P {} /app/lib \;

# 收集二进制文件
RUN mkdir -p /app/full && \
    cp build/ReleaseOV/bin/* /app/full/

# ============================================
# Base Runtime Image
# ============================================
FROM docker.io/ubuntu:${UBUNTU_VERSION} AS base

ARG BUILD_DATE
ARG APP_VERSION
ARG APP_REVISION
ARG IGC_VERSION
ARG IGC_VERSION_FULL
ARG COMPUTE_RUNTIME_VERSION
ARG COMPUTE_RUNTIME_VERSION_FULL
ARG IGDGMM_VERSION
LABEL org.opencontainers.image.created=$BUILD_DATE \
      org.opencontainers.image.version=$APP_VERSION \
      org.opencontainers.image.revision=$APP_REVISION \
      org.opencontainers.image.title="llama.cpp (OpenVINO)" \
      org.opencontainers.image.description="LLM inference in C/C++ with OpenVINO backend" \
      org.opencontainers.image.url="https://github.com/ggml-org/llama.cpp" \
      org.opencontainers.image.source="https://github.com/ggml-org/llama.cpp"

# 安装运行时最小依赖
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libgomp1 \
        libtbb12 \
        curl \
        wget \
        ca-certificates \
        ocl-icd-libopencl1 && \
    apt-get autoremove -y && \
    apt-get clean -y && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 安装 Intel GPU 驱动（from GitHub releases，确保 OpenVINO GPU plugin 可用）
# 参照 https://github.com/ggml-org/llama.cpp/blob/master/.devops/openvino.Dockerfile
RUN set -eux; \
    TMPDIR="$(mktemp -d)"; \
    cd "$TMPDIR"; \
    for url in \
        "https://github.com/intel/intel-graphics-compiler/releases/download/${IGC_VERSION}/intel-igc-core-${IGC_VERSION_FULL}_amd64.deb" \
        "https://github.com/intel/intel-graphics-compiler/releases/download/${IGC_VERSION}/intel-igc-opencl-${IGC_VERSION_FULL}_amd64.deb" \
        "https://github.com/intel/compute-runtime/releases/download/${COMPUTE_RUNTIME_VERSION}/intel-ocloc_${COMPUTE_RUNTIME_VERSION_FULL}_amd64.deb" \
        "https://github.com/intel/compute-runtime/releases/download/${COMPUTE_RUNTIME_VERSION}/intel-opencl-icd_${COMPUTE_RUNTIME_VERSION_FULL}_amd64.deb" \
        "https://github.com/intel/compute-runtime/releases/download/${COMPUTE_RUNTIME_VERSION}/libigdgmm12_${IGDGMM_VERSION}_amd64.deb" \
        "https://github.com/intel/compute-runtime/releases/download/${COMPUTE_RUNTIME_VERSION}/libze-intel-gpu1_${COMPUTE_RUNTIME_VERSION_FULL}_amd64.deb"; \
    do \
        f="$(basename "$url")"; \
        wget -q -O "$f" "$url"; \
    done; \
    apt-get update; \
    apt-get install -y --no-install-recommends ./*.deb; \
    rm -rf /var/lib/apt/lists/* "$TMPDIR"

COPY --from=build /app/lib/ /app/

WORKDIR /app

# ============================================
# Target: full — 所有二进制
# ============================================
FROM base AS full

COPY --from=build /app/full /app/

ENTRYPOINT ["/app/llama-cli"]

# ============================================
# Target: light — 仅 llama-cli
# ============================================
FROM base AS light

COPY --from=build /app/full/llama-cli /app/

ENTRYPOINT ["/app/llama-cli"]

# ============================================
# Target: server — 仅 llama-server + health check
# ============================================
FROM base AS server

ENV LLAMA_ARG_HOST=0.0.0.0
# 默认上下文大小（可被 -c 参数覆盖）
# 注意：当 -np > 1 时，每 slot 的上下文 = ctx_size / n_parallel
ENV LLAMA_ARG_CTX_SIZE=8192

COPY --from=build /app/full/llama-server /app/

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD curl -f http://localhost:8080/health || exit 1

EXPOSE 8080

ENTRYPOINT ["/app/llama-server"]

# ============================================
# Target: latest — 默认构建目标（light）
# ============================================
FROM light AS latest
