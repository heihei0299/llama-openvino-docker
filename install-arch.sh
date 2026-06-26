#!/usr/bin/env bash
# ============================================
# llama-openvino-docker — Arch Linux 一键安装脚本
# llama.cpp + OpenVINO 后端 适配 Arch Linux
# ============================================
#
# 用法:
#   chmod +x install-arch.sh
#   ./install-arch.sh
#
# 环境变量:
#   OPENVINO_METHOD=aur     # 从 AUR 安装 OpenVINO（默认；包名: openvino，支持 openvino-bin）
#   OPENVINO_METHOD=intel   # 从 Intel 官方归档下载 OpenVINO
#   LLAMA_CPP_DIR=<路径>     # 指定 llama.cpp 目录（默认克隆到当前目录）
#   BUILD_DIR=<路径>         # 构建目录（默认 build/ReleaseOV）
#   GGML_OPENVINO_DEVICE=CPU # 目标设备：CPU / GPU / NPU（默认 CPU）
#   JOBS=<数字>              # 并行编译线程数（默认自动检测）
#   USE_AUR_BIN=1            # 使用 openvino-bin（AUR 二进制包，编译更快）

set -euo pipefail

# ========== 颜色输出 ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }

# ========== 检查是否为 Arch Linux ==========
check_arch() {
    if [[ ! -f /etc/arch-release ]]; then
        err "此脚本仅适用于 Arch Linux（及其衍生版，如 EndeavourOS / Manjaro）。"
        err "当前系统未检测到 /etc/arch-release。"
        exit 1
    fi
    ok "系统检测: Arch Linux"
}

# ========== 安装 pacman 依赖 ==========
install_pacman_deps() {
    info "安装编译依赖..."

    local packages=(
        base-devel      # gcc, make 等基础编译工具
        git             # 克隆 llama.cpp
        cmake           # 构建系统
        ninja           # 加快编译
        opencl-headers  # OpenCL 头文件
        ocl-icd         # OpenCL ICD 加载器
        intel-compute-runtime  # Intel GPU OpenCL 运行时（含编译器）
        curl            # 下载工具
        wget            # 下载工具
    )

    # 检查并安装缺失的包
    local missing=()
    for pkg in "${packages[@]}"; do
        if ! pacman -Qi "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "所有依赖已安装"
    else
        info "以下依赖需要安装: ${missing[*]}"
        sudo pacman -S --needed --noconfirm "${missing[@]}"
        ok "依赖安装完成"
    fi
}

# ========== 安装 OpenVINO ==========
install_openvino_aur() {
    local aur_pkg="openvino"
    [[ "${USE_AUR_BIN:-0}" == "1" ]] && aur_pkg="openvino-bin"

    info "通过 AUR 安装 OpenVINO（包名: ${aur_pkg}）..."

    # 检测可用的 AUR Helper
    local aur_helper=""
    for helper in yay paru; do
        if command -v "$helper" &>/dev/null; then
            aur_helper="$helper"
            break
        fi
    done

    if [[ -z "$aur_helper" ]]; then
        warn "未检测到 yay 或 paru。尝试自动安装 paru..."
        if command -v git &>/dev/null && command -v makepkg &>/dev/null; then
            local tmpdir
            tmpdir="$(mktemp -d)"
            git clone https://aur.archlinux.org/paru.git "$tmpdir/paru"
            (cd "$tmpdir/paru" && makepkg -si --noconfirm)
            rm -rf "$tmpdir"
            aur_helper="paru"
            ok "paru 安装完成"
        else
            err "无法安装 AUR Helper。请手动安装 yay 或 paru，然后重新运行脚本。"
            err "参考: https://github.com/Jguer/yay 或 https://github.com/Morganamilo/paru"
            exit 1
        fi
    fi

    info "使用 $aur_helper 安装 ${aur_pkg}..."
    $aur_helper -S --needed --noconfirm "${aur_pkg}"

    # AUR openvino 安装到 /usr 前缀（标准路径），非 /opt/intel/openvino
    # CMake 通过 FindOpenVINO 或 pkg-config 自动发现
    if ldconfig -p 2>/dev/null | grep -q libopenvino; then
        ok "OpenVINO 库已正确安装至系统路径"
    else
        warn "未检测到 libopenvino 系统库，请检查安装状态"
    fi
}

install_openvino_intel() {
    info "从 Intel 官方归档安装 OpenVINO..."

    local OPENVINO_VERSION_MAJOR="2026.2"
    local OPENVINO_VERSION_FULL="2026.2.0.21903.52ddc073857"
    local OPENVINO_INSTALL_DIR="/opt/intel/openvino_${OPENVINO_VERSION_MAJOR}"
    local OPENVINO_LINK_DIR="/opt/intel/openvino"
    local OPENVINO_TGZ="/tmp/openvino.tgz"
    local OPENVINO_URL="https://storage.openvinotoolkit.org/repositories/openvino/packages/${OPENVINO_VERSION_MAJOR}/linux/openvino_toolkit_ubuntu24_${OPENVINO_VERSION_FULL}_x86_64.tgz"

    if [[ -f "${OPENVINO_INSTALL_DIR}/setupvars.sh" ]]; then
        ok "OpenVINO ${OPENVINO_VERSION_MAJOR} 已安装，跳过下载"
    else
        info "下载 OpenVINO ${OPENVINO_VERSION_MAJOR}..."
        sudo mkdir -p "$(dirname "$OPENVINO_INSTALL_DIR")"
        curl -L -o "$OPENVINO_TGZ" "$OPENVINO_URL"

        info "解压 OpenVINO 到 ${OPENVINO_INSTALL_DIR}..."
        sudo mkdir -p "$OPENVINO_INSTALL_DIR"
        sudo tar -xzf "$OPENVINO_TGZ" -C "$OPENVINO_INSTALL_DIR" --strip-components=1
        rm -f "$OPENVINO_TGZ"
        ok "OpenVINO 归档下载并解压完成"
    fi

    # 更新符号链接
    sudo ln -sfn "$OPENVINO_INSTALL_DIR" "$OPENVINO_LINK_DIR"

    # 安装 OpenVINO 运行时依赖
    if [[ -x "${OPENVINO_LINK_DIR}/install_dependencies/install_openvino_dependencies.sh" ]]; then
        info "安装 OpenVINO 运行时依赖..."
        sudo "${OPENVINO_LINK_DIR}/install_dependencies/install_openvino_dependencies.sh"
        ok "OpenVINO 运行时依赖安装完成"
    else
        warn "未找到 OpenVINO 依赖安装脚本，尝试直接继续"
    fi

    ok "OpenVINO 已安装到 ${OPENVINO_LINK_DIR} -> ${OPENVINO_INSTALL_DIR}"
}

install_openvino() {
    local method="${OPENVINO_METHOD:-aur}"
    case "$method" in
        aur)   install_openvino_aur ;;
        intel) install_openvino_intel ;;
        *)
            err "未知的 OpenVINO 安装方式: $method"
            err "请设置 OPENVINO_METHOD=aur 或 OPENVINO_METHOD=intel"
            exit 1
            ;;
    esac
}

# ========== 构建 llama.cpp ==========
build_llamacpp() {
    local llama_dir="${LLAMA_CPP_DIR:-./llama.cpp}"
    local build_dir="${BUILD_DIR:-${llama_dir}/build/ReleaseOV}"
    local jobs="${JOBS:-$(nproc)}"
    local device="${GGML_OPENVINO_DEVICE:-CPU}"

    # 克隆 repository（如不存在）
    if [[ ! -d "$llama_dir" ]]; then
        info "克隆 llama.cpp..."
        git clone --depth=1 https://github.com/ggml-org/llama.cpp.git "$llama_dir"
        ok "llama.cpp 克隆完成"
    else
        ok "llama.cpp 目录已存在: $llama_dir"
    fi

    cd "$llama_dir"

    # 加载 OpenVINO 环境变量（仅 Intel 归档方式需要）
    local OPENVINO_ROOT="/opt/intel/openvino"
    if [[ -f "$OPENVINO_ROOT/setupvars.sh" ]]; then
        info "加载 OpenVINO 环境变量（来自 Intel 归档）..."
        source "$OPENVINO_ROOT/setupvars.sh"
    else
        # AUR 方式安装的 openvino 位于系统路径，无需 setupvars.sh
        if command -v pkg-config &>/dev/null && pkg-config --exists openvino 2>/dev/null; then
            ok "OpenVINO 已通过系统 pkg-config 可用"
        else
            warn "未找到 setupvars.sh，CMake 将通过标准路径搜索 OpenVINO"
        fi
    fi

    # 创建构建目录并运行 cmake
    info "配置 CMake (设备: ${device})..."
    cmake -B "$build_dir" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_OPENVINO=ON

    # 编译
    info "开始编译（并行 ${jobs} 线程）..."
    cmake --build "$build_dir" --parallel "$jobs"

    ok "llama.cpp + OpenVINO 构建完成！"
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN} 构建成功！${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
}

# ========== 打印使用说明 ==========
print_usage() {
    local llama_dir="${LLAMA_CPP_DIR:-./llama.cpp}"
    local build_dir="${BUILD_DIR:-${llama_dir}/build/ReleaseOV}"
    local device="${GGML_OPENVINO_DEVICE:-CPU}"

    echo ""
    echo -e "${CYAN}================== 使用说明 ==================${NC}"
    echo ""
    echo "二进制文件目录: ${build_dir}/bin/"
    echo ""
    echo "运行前务必加载 OpenVINO 环境变量："
    echo "  source /opt/intel/openvino/setupvars.sh"
    echo ""
    echo "设置目标设备（CPU / GPU / NPU）："
    echo "  export GGML_OPENVINO_DEVICE=${device}"
    echo ""
    echo "（可选）启用状态化执行以提升 GPU 性能："
    echo "  export GGML_OPENVINO_STATEFUL_EXECUTION=1"
    echo ""
    echo "下载示例模型："
    echo "  mkdir -p ~/models/"
    echo "  wget https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf \\"
    echo "       -O ~/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf"
    echo ""
    echo "运行聊天模式："
    echo "  source /opt/intel/openvino/setupvars.sh"
    echo "  export GGML_OPENVINO_DEVICE=${device}"
    echo "  ${build_dir}/bin/llama-cli -m ~/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf -c 1024"
    echo ""
    echo "运行 OpenVINO benchmark："
    echo "  source /opt/intel/openvino/setupvars.sh"
    echo "  export GGML_OPENVINO_DEVICE=${device}"
    echo "  export GGML_OPENVINO_STATEFUL_EXECUTION=1"
    echo "  ${build_dir}/bin/llama-bench -m ~/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf -fa 1"
    echo ""
    echo "运行 HTTP 服务器："
    echo "  source /opt/intel/openvino/setupvars.sh"
    echo "  export GGML_OPENVINO_DEVICE=${device}"
    echo "  ${build_dir}/bin/llama-server -m ~/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf --port 8080 -c 1024"
    echo ""
    echo "NPU 使用提示（如果可用）："
    echo "  export GGML_OPENVINO_DEVICE=NPU"
    echo "  # NPU 建议使用较小上下文"
    echo "  ${build_dir}/bin/llama-cli -m ~/models/llama-model.gguf -c 512"
    echo ""
    echo -e "${YELLOW}GPU 诊断:${NC}"
    echo "  查看 Intel GPU 设备:  ls -la /dev/dri/"
    echo "  查看 GPU 信息:       sudo clinfo | grep -E 'Device Name|Device Version|Driver Version'"
    echo "  安装 clinfo:         sudo pacman -S clinfo"
    echo ""
    echo -e "${CYAN}================================================${NC}"
    echo ""
}

# ========== 主流程 ==========
main() {
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN} llama-openvino-docker — Arch Linux 安装脚本${NC}"
    echo -e "${GREEN} llama.cpp + OpenVINO 一键安装${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""

    check_arch
    install_pacman_deps
    install_openvino
    build_llamacpp
    print_usage

    echo -e "${GREEN}安装完成！请按照上方使用说明运行 llama.cpp。${NC}"
}

main "$@"
