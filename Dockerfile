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

ARG OPENVINO_STACK_VERSION=2026.2
ARG UBUNTU_VERSION=24.04

ARG BUILD_DATE=N/A
ARG APP_VERSION=N/A
ARG APP_REVISION=N/A

# ============================================
# Build Stage
# ============================================
FROM docker.io/ubuntu:${UBUNTU_VERSION} AS build

ARG OPENVINO_STACK_VERSION
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
RUN case "${OPENVINO_STACK_VERSION}" in \
        2026.2) \
            OV_MAJOR=2026.2 && \
            OV_FULL=2026.2.0.21903.52ddc073857 \
            ;; \
        *) echo "Unknown OPENVINO_STACK_VERSION: ${OPENVINO_STACK_VERSION}"; exit 1 ;; \
    esac && \
    mkdir -p /opt/intel && \
    TGZ="/tmp/openvino.tgz" && \
    wget -O "$TGZ" "https://storage.openvinotoolkit.org/repositories/openvino/packages/${OV_MAJOR}/linux/openvino_toolkit_ubuntu24_${OV_FULL}_x86_64.tgz" && \
    tar -xzf "$TGZ" -C /opt/intel/ && \
    mv "/opt/intel/openvino_toolkit_ubuntu24_${OV_FULL}_x86_64" "/opt/intel/openvino_${OV_MAJOR}" && \
    cd "/opt/intel/openvino_${OV_MAJOR}" && \
    echo "Y" | ./install_dependencies/install_openvino_dependencies.sh && \
    cd / && \
    ln -s "/opt/intel/openvino_${OV_MAJOR}" /opt/intel/openvino && \
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
        -DGGML_NATIVE=OFF \
        -DGGML_BACKEND_DL=ON \
        -DGGML_CPU_ALL_VARIANTS=ON \
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

ARG OPENVINO_STACK_VERSION
ARG BUILD_DATE
ARG APP_VERSION
ARG APP_REVISION
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
COPY scripts/install-gpu-drivers.sh /tmp/
RUN set -eux; \
    case "${OPENVINO_STACK_VERSION}" in \
        2026.2) \
            IGC_VER=v2.36.3 && \
            IGC_FULL=2_2.36.3+21719 && \
            CR_VER=26.22.38646.4 && \
            CR_FULL=26.22.38646.4-0 && \
            IGDGMM_VER=22.10.0 \
            ;; \
        *) echo "Unknown OPENVINO_STACK_VERSION: ${OPENVINO_STACK_VERSION}"; exit 1 ;; \
    esac; \
    /tmp/install-gpu-drivers.sh "$IGC_VER" "$IGC_FULL" "$CR_VER" "$CR_FULL" "$IGDGMM_VER"

COPY --from=build /app/lib/ /app/

# 安装 Intel NPU 驱动（确保 OpenVINO NPU plugin 可用）
# 参照 https://github.com/ggml-org/llama.cpp/blob/master/.devops/openvino.Dockerfile
# 注意：当前 OPENVINO 2026.2 对应 NPU 驱动版本经实测选用 v1.35.0 + libze1 1.28.2
ARG NPU_DRIVER_VERSION=v1.35.0
ARG NPU_DRIVER_FULL=v1.35.0.20260722-29947505341
ARG LIBZE1_VERSION=1.28.2-1~24.04~ppa1
RUN set -eux; \
    TMPDIR="$(mktemp -d)"; \
    cd "$TMPDIR"; \
    TGZ="linux-npu-driver-${NPU_DRIVER_FULL}-ubuntu2404.tar.gz"; \
    wget -q -O "$TGZ" "https://github.com/intel/linux-npu-driver/releases/download/${NPU_DRIVER_VERSION}/linux-npu-driver-${NPU_DRIVER_FULL}-ubuntu2404.tar.gz"; \
    mkdir -p npu && tar -xf "$TGZ" -C npu; \
    wget -q -O "libze1_${LIBZE1_VERSION}_amd64.deb" "https://snapshot.ppa.launchpadcontent.net/kobuk-team/intel-graphics/ubuntu/20260606T100000Z/pool/main/l/level-zero-loader/libze1_${LIBZE1_VERSION}_amd64.deb"; \
    cp "libze1_${LIBZE1_VERSION}_amd64.deb" npu/; \
    apt-get update; \
    apt-get install -y --no-install-recommends npu/*.deb; \
    rm -rf /var/lib/apt/lists/* "$TMPDIR"

# OpenVINO 模型编译缓存（持久化可挂载 -v ov_cache:/tmp/ov_cache）
# NPU 不支持该缓存，CPU/GPU 可显著降低二次启动编译时间
ENV GGML_OPENVINO_CACHE_DIR=/tmp/ov_cache
RUN mkdir -p /tmp/ov_cache

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
# 激进默认值：Flash Attention 常开可降低长上下文 KV 读写，提升吞吐
ENV LLAMA_ARG_FLASH_ATTN=1
# 逻辑 batch / 物理 batch：兼顾 prompt 吞吐与高并发 KV 压力；可用 -b/-ub 覆盖
ENV LLAMA_ARG_BATCH=512
ENV LLAMA_ARG_UBATCH=512
COPY --from=build /app/full/llama-server /app/

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD curl -f http://localhost:8080/health || exit 1

EXPOSE 8080

ENTRYPOINT ["/app/llama-server"]

# ============================================
# Target: latest — 默认构建目标（light）
# ============================================
FROM light AS latest
