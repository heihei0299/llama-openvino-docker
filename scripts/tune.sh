#!/usr/bin/env bash
# tune.sh — 推理性能调优推荐脚本（CPU / GPU / NPU × CLI / Server）
#
# 保持兼容：仅输出推荐值，不修改系统；可直接复制执行
# 用法:
#   scripts/tune.sh [--device cpu|gpu|npu|auto] [--scenario cli|server|auto] [--model /path/to/model.gguf] [--ctx-size N] [--parallel N] [--output env|cmd|all]
#   scripts/tune.sh --help

set -euo pipefail

DEVICE="auto"
SCENARIO="auto"
MODEL=""
CTX_SIZE=""
PARALLEL=""
OUTPUT="all"

print_help() {
    cat <<'EOF'
tune.sh — OpenVINO 推理调优推荐

用法:
  scripts/tune.sh [OPTIONS]

选项:
  --device <cpu|gpu|npu|auto>   目标设备，auto 时自动探测 /dev/dri、/dev/accel (默认: auto)
  --scenario <cli|server|auto>  场景，auto 时默认 server (默认: auto)
  --model <path>                模型路径，仅用于生成完整命令示例
  --ctx-size <N>                覆盖上下文大小
  --parallel <N>                覆盖 server 并行 slot 数 (-np)
  --output <env|cmd|all>        输出内容：仅环境变量 / 仅命令 / 全部 (默认: all)
  -h, --help                    显示此帮助

示例:
  scripts/tune.sh --device gpu --scenario server --model /models/Llama-3.2-1B-Q4_K_M.gguf
  scripts/tune.sh --device cpu --scenario cli
  scripts/tune.sh --device npu --ctx-size 512

输出说明:
  - ENV 区：可直接 export 或传给 docker --env
  - CMD 区：可直接复制执行（已包含官方推荐的激进默认值）
  - 诊断区：探测到的核数、设备节点、缓存目录建议

矩阵来源: README / PARAMETERS.md / docs/backend/OPENVINO.md + 本仓库 Dockerfile 默认值
EOF
}

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --scenario) SCENARIO="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --ctx-size) CTX_SIZE="$2"; shift 2 ;;
        --parallel) PARALLEL="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        -h|--help) print_help; exit 0 ;;
        *) echo "未知参数: $1" >&2; print_help; exit 1 ;;
    esac
done

# 规范化
DEVICE=$(echo "$DEVICE" | tr '[:upper:]' '[:lower:]')
SCENARIO=$(echo "$SCENARIO" | tr '[:upper:]' '[:lower:]')
OUTPUT=$(echo "$OUTPUT" | tr '[:upper:]' '[:lower:]')

# 自动探测设备
detect_device() {
    if [[ "$DEVICE" != "auto" ]]; then
        echo "$DEVICE"
        return
    fi
    local has_accel=0 has_dri=0
    for f in /dev/accel/*; do [[ -e "$f" ]] && has_accel=1 && break; done
    for f in /dev/dri/render*; do [[ -e "$f" ]] && has_dri=1 && break; done
    if [[ $has_accel -eq 1 ]]; then
        if [[ $has_dri -eq 1 ]]; then
            echo "gpu"
        else
            echo "npu"
        fi
        return
    fi
    if [[ $has_dri -eq 1 ]]; then
        echo "gpu"
        return
    fi
    echo "cpu"
}

# 自动场景
detect_scenario() {
    if [[ "$SCENARIO" != "auto" ]]; then
        echo "$SCENARIO"
        return
    fi
    # 默认 server（更常见的高并发场景）；如需 cli 请显式传参
    echo "server"
}

REAL_DEVICE=$(detect_device)
REAL_SCENARIO=$(detect_scenario)

# 探测核数
CORES=$(nproc 2>/dev/null || echo 4)
# 合理并行度：server 下每 slot 至少 1024 tokens 才不频繁溢出
recommend_parallel() {
    if [[ -n "$PARALLEL" ]]; then echo "$PARALLEL"; return; fi
    if [[ "$REAL_SCENARIO" == "cli" ]]; then echo "1"; return; fi
    # NPU 仅支持单序列
    if [[ "$REAL_DEVICE" == "npu" ]]; then echo "1"; return; fi
    # server 场景：核数 ≤4 时用核数；>4 时 cap 到 4，避免每 slot 过小
    if [[ "$CORES" -le 4 ]]; then echo "$CORES"; else echo "4"; fi
}

RECOMMEND_NP=$(recommend_parallel)

recommend_ctx() {
    if [[ -n "$CTX_SIZE" ]]; then echo "$CTX_SIZE"; return; fi
    case "$REAL_DEVICE" in
        npu) echo "512" ;;
        *)  # cpu/gpu
            if [[ "$REAL_SCENARIO" == "cli" ]]; then echo "2048"; else echo "8192"; fi
            ;;
    esac
}

RECOMMEND_CTX=$(recommend_ctx)

# 设备分级矩阵
# 返回值通过全局变量展示
case "$REAL_DEVICE" in
    cpu)
        ENV_DEVICE="CPU"
        ENV_STATEFUL="0"
        ENV_CACHE_DIR="/tmp/ov_cache"
        ENV_PREFILL=""
        EXTRA_FLAGS="-fa 1"
        BATCH="512"
        UBATCH="512"
        THREADS="$CORES"
        NOTE="CPU：兼容性最佳。STATEFUL=0 保持 server 多 slot 可用；单 slot 低延迟可改 1。CACHE_DIR 持久化可显著降低二次启动编译时间。"
        ;;
    gpu)
        ENV_DEVICE="GPU"
        ENV_STATEFUL="1"
        ENV_CACHE_DIR="/tmp/ov_cache"
        ENV_PREFILL=""
        EXTRA_FLAGS="-fa 1"
        BATCH="512"
        UBATCH="512"
        THREADS="$CORES"
        NOTE="GPU：强烈建议 STATEFUL=1（本镜像 server 已设 FLASH_ATTN=1）。需挂载 --device=/dev/dri 并设置 group-add；server 多 slot 时注意 STATEFUL 仅支持单会话，可按需改 0。"
        ;;
    npu)
        ENV_DEVICE="NPU"
        ENV_STATEFUL="0"
        ENV_CACHE_DIR=""
        ENV_PREFILL="256"
        EXTRA_FLAGS="-fa 1"
        BATCH="256"
        UBATCH="256"
        THREADS="$CORES"
        NOTE="NPU：必须限制 -c 512（默认可能 131072 导致 OOM）；不支持 GGML_OPENVINO_CACHE_DIR 与多序列；prefill_chunk 256。"
        ;;
    *)
        echo "不支持的设备: $REAL_DEVICE" >&2; exit 1
        ;;
esac

# 若用户显式覆盖 STATEFUL/GPU 等，仍以矩阵为准；脚本仅建议
MODEL_FLAG=""
if [[ -n "$MODEL" ]]; then
    MODEL_FLAG="-m $MODEL"
else
    MODEL_FLAG="-m /models/Llama-3.2-1B-Instruct-Q4_K_M.gguf  # ← 替换为你的模型路径"
fi

# 生成 ENV 块
gen_env_block() {
    echo "# --- ENV 推荐（${REAL_DEVICE^^} / ${REAL_SCENARIO}）---"
    echo "export GGML_OPENVINO_DEVICE=${ENV_DEVICE}"
    if [[ -n "$ENV_CACHE_DIR" ]]; then
        echo "export GGML_OPENVINO_CACHE_DIR=${ENV_CACHE_DIR}  # 建议挂载持久卷: -v ov_cache:${ENV_CACHE_DIR}"
    else
        echo "# NPU 不支持 GGML_OPENVINO_CACHE_DIR，保持未设置"
    fi
    if [[ "$REAL_DEVICE" == "gpu" ]]; then
        echo "export GGML_OPENVINO_STATEFUL_EXECUTION=${ENV_STATEFUL}  # GPU 推荐 1；server 多 slot/多会话时改 0"
    else
        echo "export GGML_OPENVINO_STATEFUL_EXECUTION=${ENV_STATEFUL}"
    fi
    if [[ -n "$ENV_PREFILL" ]]; then
        echo "export GGML_OPENVINO_PREFILL_CHUNK_SIZE=${ENV_PREFILL}"
    fi
}

gen_cli_cmd() {
    local ctx="$RECOMMEND_CTX"
    echo "# --- CLI 命令推荐 ---"
    if [[ "$REAL_DEVICE" == "gpu" ]]; then
        echo "docker run --rm -it -v ~/models:/models \\"
        echo "  --device=/dev/dri --group-add=\$(stat -c \"%g\" /dev/dri/render* 2>/dev/null | head -n 1) \\"
        echo "  -u \$(id -u):\$(id -g) \\"
        echo "  --env=GGML_OPENVINO_DEVICE=${ENV_DEVICE} --env=GGML_OPENVINO_STATEFUL_EXECUTION=${ENV_STATEFUL} \\"
        if [[ -n "$ENV_CACHE_DIR" ]]; then echo "  --env=GGML_OPENVINO_CACHE_DIR=${ENV_CACHE_DIR} -v ov_cache:${ENV_CACHE_DIR} \\"; fi
        echo "  ghcr.io/heihei0299/llama-openvino-docker:light \\"
        echo "  ${MODEL_FLAG} -c ${ctx} -b ${BATCH} --ubatch-size ${UBATCH} -t ${THREADS} ${EXTRA_FLAGS} --temp 0 -n 256 --no-warmup -p \"Hello\""
    elif [[ "$REAL_DEVICE" == "npu" ]]; then
        echo "docker run --rm -it -v ~/models:/models \\"
        echo "  --device=/dev/accel --group-add=\$(stat -c \"%g\" /dev/dri/render* 2>/dev/null | head -n 1) \\"
        echo "  -u \$(id -u):\$(id -g) \\"
        echo "  --env=GGML_OPENVINO_DEVICE=${ENV_DEVICE} --env=GGML_OPENVINO_PREFILL_CHUNK_SIZE=${ENV_PREFILL} \\"
        echo "  ghcr.io/heihei0299/llama-openvino-docker:light \\"
        echo "  ${MODEL_FLAG} -c ${ctx} -b ${BATCH} --ubatch-size ${UBATCH} -t ${THREADS} ${EXTRA_FLAGS} --temp 0 -n 256 --no-warmup -p \"Hello\""
    else
        echo "docker run --rm -it -v ~/models:/models \\"
        echo "  --env=GGML_OPENVINO_DEVICE=${ENV_DEVICE} --env=GGML_OPENVINO_STATEFUL_EXECUTION=${ENV_STATEFUL} \\"
        if [[ -n "$ENV_CACHE_DIR" ]]; then echo "  --env=GGML_OPENVINO_CACHE_DIR=${ENV_CACHE_DIR} -v ov_cache:${ENV_CACHE_DIR} \\"; fi
        echo "  ghcr.io/heihei0299/llama-openvino-docker:light \\"
        echo "  ${MODEL_FLAG} -c ${ctx} -b ${BATCH} --ubatch-size ${UBATCH} -t ${THREADS} ${EXTRA_FLAGS} --temp 0 -n 256 --no-warmup -p \"Hello\""
    fi
}

gen_server_cmd() {
    local ctx="$RECOMMEND_CTX"
    local np="$RECOMMEND_NP"
    local per_slot=$(( ctx / np ))
    echo "# --- Server 命令推荐（每 slot ≈ ${per_slot} tokens）---"
    if [[ "$REAL_DEVICE" == "gpu" ]]; then
        echo "docker run --rm -it -p 8080:8080 -v ~/models:/models \\"
        echo "  --device=/dev/dri --group-add=\$(stat -c \"%g\" /dev/dri/render* 2>/dev/null | head -n 1) \\"
        echo "  -u \$(id -u):\$(id -g) \\"
        echo "  --env=GGML_OPENVINO_DEVICE=${ENV_DEVICE} --env=GGML_OPENVINO_STATEFUL_EXECUTION=${ENV_STATEFUL} \\"
        if [[ -n "$ENV_CACHE_DIR" ]]; then echo "  --env=GGML_OPENVINO_CACHE_DIR=${ENV_CACHE_DIR} -v ov_cache:${ENV_CACHE_DIR} \\"; fi
        echo "  ghcr.io/heihei0299/llama-openvino-docker:server \\"
        echo "  ${MODEL_FLAG} -c ${ctx} -np ${np} -b ${BATCH} --ubatch-size ${UBATCH} -t ${THREADS} --host 0.0.0.0 --port 8080"
        echo "# 提示: STATEFUL=1 仅支持单会话；高并发多用户改 --env=GGML_OPENVINO_STATEFUL_EXECUTION=0"
    elif [[ "$REAL_DEVICE" == "npu" ]]; then
        echo "docker run --rm -it -p 8080:8080 -v ~/models:/models \\"
        echo "  --device=/dev/accel --group-add=\$(stat -c \"%g\" /dev/dri/render* 2>/dev/null | head -n 1) \\"
        echo "  -u \$(id -u):\$(id -g) \\"
        echo "  --env=GGML_OPENVINO_DEVICE=${ENV_DEVICE} --env=GGML_OPENVINO_PREFILL_CHUNK_SIZE=${ENV_PREFILL} \\"
        echo "  ghcr.io/heihei0299/llama-openvino-docker:server \\"
        echo "  ${MODEL_FLAG} -c ${ctx} -np 1 -b ${BATCH} --ubatch-size ${UBATCH} -t ${THREADS} --host 0.0.0.0 --port 8080"
        echo "# 提示: NPU 固定 -np 1 且 -c 512，不支持多序列与 CACHE_DIR"
    else
        echo "docker run --rm -it -p 8080:8080 -v ~/models:/models \\"
        echo "  --env=GGML_OPENVINO_DEVICE=${ENV_DEVICE} --env=GGML_OPENVINO_STATEFUL_EXECUTION=${ENV_STATEFUL} \\"
        if [[ -n "$ENV_CACHE_DIR" ]]; then echo "  --env=GGML_OPENVINO_CACHE_DIR=${ENV_CACHE_DIR} -v ov_cache:${ENV_CACHE_DIR} \\"; fi
        echo "  ghcr.io/heihei0299/llama-openvino-docker:server \\"
        echo "  ${MODEL_FLAG} -c ${ctx} -np ${np} -b ${BATCH} --ubatch-size ${UBATCH} -t ${THREADS} --host 0.0.0.0 --port 8080"
    fi
    echo "# 每 slot 可用 tokens = -c / -np = ${ctx} / ${np} = ${per_slot}"
    if [[ $per_slot -lt 1024 ]]; then
        echo "# ⚠ 每 slot <1024，易触发 Context size exceeded；建议增大 -c 或减小 -np"
    fi
}

# 输出
echo "===== tune.sh 诊断 ====="
echo "探测核数: ${CORES}"
echo "探测设备: ${REAL_DEVICE} (输入: ${DEVICE})"
echo "场景: ${REAL_SCENARIO} (输入: ${SCENARIO})"
echo "推荐上下文: ${RECOMMEND_CTX}  推荐并行: ${RECOMMEND_NP}  线程: ${THREADS}  batch: ${BATCH}/${UBATCH}"
echo "说明: ${NOTE}"
echo ""

if [[ "$OUTPUT" == "env" || "$OUTPUT" == "all" ]]; then
    gen_env_block
    echo ""
fi

if [[ "$OUTPUT" == "cmd" || "$OUTPUT" == "all" ]]; then
    if [[ "$REAL_SCENARIO" == "cli" ]]; then
        gen_cli_cmd
    else
        gen_server_cmd
    fi
    echo ""
fi

if [[ "$OUTPUT" == "all" ]]; then
    echo "# --- 额外调优建议 ---"
    echo "# 1) 持久化编译缓存：docker volume create ov_cache && -v ov_cache:/tmp/ov_cache"
    echo "# 2) 基准压测：scripts/benchmark.sh -m <model> --device ${REAL_DEVICE} -p 512 -n 128 -r 5"
    echo "# 3) 线程亲和：高核数机器可尝试 -C 0xFF / --cpu-range 0-7 绑定，减少跨 NUMA"
    echo "# 4) Flash Attention 已在 server 镜像默认开启（LLAMA_ARG_FLASH_ATTN=1），CLI 请显式 -fa 1"
    echo "# 5) NPU 场景务必 -c 512；GPU 场景若 server 多用户并发，改 STATEFUL=0"
fi
