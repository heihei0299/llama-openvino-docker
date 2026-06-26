# llama-openvino-docker

Docker 化部署 llama.cpp + OpenVINO 后端的安装方案。

## Project

- **Goal**: 提供跨 Linux 发行版的一键安装脚本，简化 llama.cpp 与 Intel OpenVINO 后端的编译部署
- **Stack**: Bash 脚本，无外部依赖
- **Entry point**: `install-arch.sh` — Arch Linux 安装脚本（当前唯一实现）
- **Package manager target**: Arch Linux (`pacman` + AUR)

## Commands

```bash
# 语法检查
bash -n install-arch.sh

# 运行安装（Arch Linux）
chmod +x install-arch.sh
./install-arch.sh

# 使用 openvino-bin 二进制包（更快）
USE_AUR_BIN=1 ./install-arch.sh

# 使用 Intel 官方归档而非 AUR
OPENVINO_METHOD=intel ./install-arch.sh
```

无测试框架、无 lint 工具；验证方式为 bash 语法检查 + 执行验证。

## Architecture

```
llama-openvino-docker/
├── README.md           # 项目说明 + 快速开始
├── install-arch.sh     # Arch Linux 安装脚本
├── Dockerfile          # Docker 多阶段构建（OpenVINO 后端）
└── AGENTS.md           # 本文件
```

`install-arch.sh` 内部模块：

1. **check_arch** — 检测 `/etc/arch-release`
2. **install_pacman_deps** — 通过 `pacman` 安装编译工具链（`base-devel`, `cmake`, `ninja`, `opencl-headers`, `ocl-icd`, `intel-graphics-compiler` 等）
3. **install_openvino** — 两种方式：
   - `aur`（默认）：通过 yay/paru 安装 `openvino`（或 `openvino-bin`），自动安装 paru 如果缺失
   - `intel`：从 Intel 官方归档下载 openvino_toolkit 2026.2 并解压到 `/opt/intel/openvino`
4. **build_llamacpp** — 克隆 `ggml-org/llama.cpp` 并用 CMake + Ninja 构建（`-DGGML_OPENVINO=ON`）
5. **print_usage** — 打印使用说明（设备选择、模型下载、运行示例）

可配置的环境变量：`OPENVINO_METHOD`, `USE_AUR_BIN`, `LLAMA_CPP_DIR`, `BUILD_DIR`, `GGML_OPENVINO_DEVICE`, `JOBS`

## Docker 构建目标

| 目标 | 说明 |
|------|------|
| `base` | 运行时库 + 最小依赖（OCL-ICD） |
| `full` | 所有二进制 + Python 工具 |
| `light` | 仅 llama-cli |
| `server` | 仅 llama-server + health check |

构建命令示例：`docker build --target=light -t llama-openvino:light .`

GPU 透传：`--device=/dev/dri --group-add=$(stat -c "%g" /dev/dri/render* | head -n 1)`
NPU 透传：`--device=/dev/accel`

## Conventions

- **语言**: 中文注释 + 中文用户输出（脚本内错误/提示信息使用中文）
- **Bash 风格**: `set -euo pipefail`；使用 `local` 变量；颜色输出函数 `info()`/`ok()`/`warn()`/`err()`
- **错误处理**: 关键步骤 `exit 1` 终止，非关键步骤使用 `warn` 继续
- **验证**: 使用 `pacman -Qi` 检查包是否已安装；使用 `ldconfig -p` 检测系统库
- **权限**: `sudo` 用于 `pacman` 安装和写入 `/opt/intel`；AUR helper 调用无需 sudo
- **不**: 不使用 `makepkg` 打包（脚本直接从源码构建）

## Notes

（留白供后续补充）
