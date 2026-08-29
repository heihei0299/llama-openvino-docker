#!/usr/bin/env bash
# benchmark.sh — OpenVINO 压测封装（基于 llama-bench）
# 基线：Llama-3.2-1B-Instruct Q4_K_M，p512 n128，-fa 1，重复 5 次
#
# 用法:
#   scripts/benchmark.sh -m <model.gguf> [--device cpu|gpu|npu|auto] [-p 512] [-n 128] [-r 5] [-o md|csv|json] [--output-file result.md] [--threads N] [--matrix] [--docker]
#   scripts/benchmark.sh --help

set -euo pipefail

MODEL=""
DEVICE="auto"
PROMPT=512
NGEN=128
REPS=5
OUTPUT="md"
OUTPUT_FILE=""
THREADS=""
MATRIX=false
DOCKER=false
CTX_SIZE=""

print_help() {
    cat <<'EOF'
benchmark.sh — llama-bench 压测封装

用法:
  scripts/benchmark.sh -m <model.gguf> [OPTIONS]

必选:
  -m, --model <path>            模型路径（GGUF）

可选:
  --device <cpu|gpu|npu|auto>   目标设备，auto 时探测 /dev/dri、/dev/accel (默认: auto)
  -p, --n-prompt <N>            prompt 长度 (默认: 512)
  -n, --n-gen <N>               生成长度 (默认: 128)
  -r, --repetitions <N>         重复次数 (默认: 5)
  -o, --output <md|csv|json>    输出格式 (默认: md)
  --output-file <path>          结果写入文件（同时输出到 stdout）
  --threads <N>                 线程数，默认 nproc
  --ctx-size <N>                上下文大小，默认按设备自动（NPU 512，其它 2048）
  --matrix                      运行矩阵：p=[128,512,1024] × n=[32,128] 组合
  --docker                      使用 Docker 镜像运行（否则要求宿主机已安装 llama-bench）
  -h, --help                    显示帮助

示例:
  # 宿主机直接压测（需已编译 llama-bench）
  scripts/benchmark.sh -m ~/models/Llama-3.2-1B-Q4_K_M.gguf --device cpu -p 512 -n 128 -r 5 -o md

  # Docker 压测（推荐，无需本地编译）
  scripts/benchmark.sh -m /models/Llama-3.2-1B-Q4_K_M.gguf --device gpu --docker -p 512 -n 128

  # 矩阵压测
  scripts/benchmark.sh -m ~/models/model.gguf --device cpu --matrix -o csv --output-file result.csv

  # 先用调优脚本获取推荐参数，再压测
  scripts/tune.sh --device gpu --scenario cli
  scripts/benchmark.sh -m /models/model.gguf --device gpu --docker

说明:
  - OpenVINO 后端必须加 -fa 1（脚本已默认追加）
  - NPU 场景自动限制 -c 512
  - 压测前建议用 scripts/tune.sh 确认 GGML_OPENVINO_* 环境
EOF
}

# 解析
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model) MODEL="$2"; shift 2 ;;
        --device) DEVICE="$2"; shift 2 ;;
        -p|--n-prompt) PROMPT="$2"; shift 2 ;;
        -n|--n-gen) NGEN="$2"; shift 2 ;;
        -r|--repetitions) REPS="$2"; shift 2 ;;
        -o|--output) OUTPUT="$2"; shift 2 ;;
        --output-file) OUTPUT_FILE="$2"; shift 2 ;;
        --threads) THREADS="$2"; shift 2 ;;
        --ctx-size) CTX_SIZE="$2"; shift 2 ;;
        --matrix) MATRIX=true; shift ;;
        --docker) DOCKER=true; shift ;;
        -h|--help) print_help; exit 0 ;;
        *) echo "未知参数: $1" >&2; print_help; exit 1 ;;
    esac
done

if [[ -z "$MODEL" ]]; then
    echo "错误: 必须指定 -m <model.gguf>" >&2
    print_help
    exit 1
fi

DEVICE=$(echo "$DEVICE" | tr '[:upper:]' '[:lower:]')
OUTPUT=$(echo "$OUTPUT" | tr '[:upper:]' '[:lower:]')

detect_device() {
    if [[ "$DEVICE" != "auto" ]]; then echo "$DEVICE"; return; fi
    local has_accel=0 has_dri=0
    for f in /dev/accel/*; do [[ -e "$f" ]] && has_accel=1 && break; done
    for f in /dev/dri/render*; do [[ -e "$f" ]] && has_dri=1 && break; done
    if [[ $has_accel -eq 1 ]]; then
        if [[ $has_dri -eq 1 ]]; then echo "gpu"; else echo "npu"; fi
        return
    fi
    if [[ $has_dri -eq 1 ]]; then echo "gpu"; return; fi
    echo "cpu"
}

REAL_DEVICE=$(detect_device)
CORES=$(nproc 2>/dev/null || echo 4)
if [[ -z "$THREADS" ]]; then THREADS="$CORES"; fi

if [[ -z "$CTX_SIZE" ]]; then
    if [[ "$REAL_DEVICE" == "npu" ]]; then CTX_SIZE=512; else CTX_SIZE=2048; fi
fi

# 设备 ENV 矩阵（与 tune.sh 保持一致）
case "$REAL_DEVICE" in
    cpu)
        ENV_DEVICE="CPU"
        ENV_STATEFUL="0"
        ENV_CACHE="/tmp/ov_cache"
        EXTRA_ENV="GGML_OPENVINO_DEVICE=${ENV_DEVICE} GGML_OPENVINO_STATEFUL_EXECUTION=${ENV_STATEFUL} GGML_OPENVINO_CACHE_DIR=${ENV_CACHE}"
        ;;
    gpu)
        ENV_DEVICE="GPU"
        ENV_STATEFUL="1"
        ENV_CACHE="/tmp/ov_cache"
        EXTRA_ENV="GGML_OPENVINO_DEVICE=${ENV_DEVICE} GGML_OPENVINO_STATEFUL_EXECUTION=${ENV_STATEFUL} GGML_OPENVINO_CACHE_DIR=${ENV_CACHE}"
        ;;
    npu)
        ENV_DEVICE="NPU"
        EXTRA_ENV="GGML_OPENVINO_DEVICE=${ENV_DEVICE} GGML_OPENVINO_PREFILL_CHUNK_SIZE=256"
        ;;
    *) echo "不支持的设备: $REAL_DEVICE" >&2; exit 1 ;;
esac

# 检查模型存在（docker 模式下为容器内路径，跳过宿主机检查）
if [[ "$DOCKER" == false && ! -f "$MODEL" ]]; then
    echo "错误: 模型文件不存在: $MODEL" >&2
    exit 1
fi

# 查找 llama-bench
find_bench() {
    if command -v llama-bench >/dev/null 2>&1; then echo "llama-bench"; return; fi
    if [[ -x ./build/ReleaseOV/bin/llama-bench ]]; then echo "./build/ReleaseOV/bin/llama-bench"; return; fi
    if [[ -x ./llama-bench ]]; then echo "./llama-bench"; return; fi
    if [[ -x /app/llama-bench ]]; then echo "/app/llama-bench"; return; fi
    echo ""
}

run_bench() {
    local p="$1" n="$2" r="$3" out="$4"
    local bench
    if [[ "$DOCKER" == true ]]; then
        # Docker 模式：bench 需用 full 镜像（含 llama-bench）
        local image="ghcr.io/heihei0299/llama-openvino-docker:full"
        if docker image inspect llama-openvino:full >/dev/null 2>&1; then
            image="llama-openvino:full"
        fi
        local docker_env=()
        case "$REAL_DEVICE" in
            gpu)
                docker_env=(--device=/dev/dri --group-add="$(stat -c "%g" /dev/dri/render* 2>/dev/null | head -n 1 || echo 0)" -u "$(id -u):$(id -g)" --env=GGML_OPENVINO_DEVICE=GPU --env=GGML_OPENVINO_STATEFUL_EXECUTION=1 --env=GGML_OPENVINO_CACHE_DIR=/tmp/ov_cache -v ov_cache:/tmp/ov_cache)
                ;;
            npu)
                docker_env=(--device=/dev/accel --group-add="$(stat -c "%g" /dev/dri/render* 2>/dev/null | head -n 1 || echo 0)" -u "$(id -u):$(id -g)" --env=GGML_OPENVINO_DEVICE=NPU --env=GGML_OPENVINO_PREFILL_CHUNK_SIZE=256)
                ;;
            cpu)
                docker_env=(--env=GGML_OPENVINO_DEVICE=CPU --env=GGML_OPENVINO_STATEFUL_EXECUTION=0 --env=GGML_OPENVINO_CACHE_DIR=/tmp/ov_cache -v ov_cache:/tmp/ov_cache)
                ;;
        esac
        # 模型挂载：转换为数组避免 word splitting 误报警
        local model_mount_args=()
        if [[ "$MODEL" == /models/* ]]; then
            model_mount_args=(-v "$HOME/models:/models")
        else
            local host_dir
            host_dir=$(dirname "$MODEL")
            model_mount_args=(-v "${host_dir}:/models")
            MODEL="/models/$(basename "$MODEL")"
        fi
        echo ">>> Docker 压测: p=${p} n=${n} r=${r} device=${REAL_DEVICE} threads=${THREADS} ctx=${CTX_SIZE}" >&2
        docker run --rm --entrypoint /app/llama-bench "${model_mount_args[@]}" "${docker_env[@]}" "$image" \
            -m "$MODEL" -p "$p" -n "$n" -r "$r" -o "$out" -t "$THREADS" -c "$CTX_SIZE" -fa 1 --no-warmup 2>&1
        return
    fi

    bench=$(find_bench)
    if [[ -z "$bench" ]]; then
        echo "错误: 未找到 llama-bench。请先编译或使用 --docker 模式" >&2
        echo "  编译: git clone https://github.com/ggml-org/llama.cpp && cmake -B build -DGGML_OPENVINO=ON && cmake --build build --parallel" >&2
        echo "  或: docker build -t llama-openvino:light .  && scripts/benchmark.sh --docker -m /models/model.gguf" >&2
        exit 1
    fi
    echo ">>> 压测: ${bench} -m ${MODEL} -p ${p} -n ${n} -r ${r} -o ${out} -t ${THREADS} -c ${CTX_SIZE} -fa 1 device=${REAL_DEVICE}" >&2
    # shellcheck disable=SC2086
    env $EXTRA_ENV "$bench" -m "$MODEL" -p "$p" -n "$n" -r "$r" -o "$out" -t "$THREADS" -c "$CTX_SIZE" -fa 1 --no-warmup 2>&1
}

# 主流程
echo "===== benchmark.sh =====" >&2
echo "设备: ${REAL_DEVICE} (输入: ${DEVICE})  线程: ${THREADS}  上下文: ${CTX_SIZE}  ENV: ${EXTRA_ENV}" >&2
echo "模型: ${MODEL}  输出格式: ${OUTPUT}  模式: $([[ "$DOCKER" == true ]] && echo docker || echo host)" >&2
echo "" >&2

OUTPUT_CAPTURE=""
if [[ "$MATRIX" == true ]]; then
    # 矩阵压测
    P_LIST=(128 512 1024)
    N_LIST=(32 128)
    # 允许用户覆盖 p/n 时，矩阵仍用列表；若用户传了单一值，尊重用户值仅跑单点
    # 这里按矩阵列表跑，忽略单值 p/n
    echo "# benchmark matrix: model=${MODEL} device=${REAL_DEVICE} threads=${THREADS} ctx=${CTX_SIZE} reps=${REPS}" >&2
    for p in "${P_LIST[@]}"; do
        for n in "${N_LIST[@]}"; do
            echo "" >&2
            echo "--- p=${p} n=${n} ---" >&2
            out=$(run_bench "$p" "$n" "$REPS" "$OUTPUT")
            echo "$out"
            OUTPUT_CAPTURE+="$out"$'\n'
            # 若指定输出文件，追加
            if [[ -n "$OUTPUT_FILE" ]]; then
                echo "$out" >> "$OUTPUT_FILE"
            fi
        done
    done
    echo "" >&2
    echo "提示: 对比不同 p/n 下的 prompt 吞吐 (pp) 与生成吞吐 (tg)，关注 tg 对交互延迟的影响" >&2
else
    out=$(run_bench "$PROMPT" "$NGEN" "$REPS" "$OUTPUT")
    echo "$out"
    OUTPUT_CAPTURE="$out"
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "$out" > "$OUTPUT_FILE"
        echo "结果已写入: $OUTPUT_FILE" >&2
    fi
fi

# 简单解析与摘要（仅 md/csv 可解析）
echo "" >&2
echo "===== 摘要 =====" >&2
echo "设备=${REAL_DEVICE}  threads=${THREADS}  ctx=${CTX_SIZE}  flash_attn=1" >&2
echo "建议: 用 scripts/tune.sh 复核 GGML_OPENVINO_* 与 -b/-ub 是否匹配压测场景" >&2
echo "下一步: 对比优化前后可用相同命令重复压测，或加 --matrix 观察不同长度表现" >&2
