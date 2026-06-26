# llama-openvino-docker

Docker 化部署 llama.cpp + OpenVINO 后端的安装方案。

## Project

- **Goal**: 提供 Docker 化方案，简化 llama.cpp 与 Intel OpenVINO 后端的编译部署
- **Stack**: Dockerfile + Bash
- **Entry point**: `Dockerfile` — 多阶段构建
- **Docker base**: Ubuntu 24.04

## Commands

```bash
# 构建各目标
docker build --target=base   -t llama-openvino:base   .
docker build --target=full   -t llama-openvino:full   .
docker build --target=light  -t llama-openvino:light  .
docker build --target=server -t llama-openvino:server .
docker build                  -t llama-openvino:latest .

# 运行（CPU）
docker run --rm -it -v ~/models:/models llama-openvino:light \
    --no-warmup -c 1024 -m /models/model.gguf

# 运行（Intel GPU）
docker run --rm -it -v ~/models:/models \
    --device=/dev/dri \
    --group-add=$(stat -c "%g" /dev/dri/render* | head -n 1) \
    -u $(id -u):$(id -g) \
    --env=GGML_OPENVINO_DEVICE=GPU \
    --env=GGML_OPENVINO_STATEFUL_EXECUTION=1 \
    llama-openvino:light \
    --no-warmup -c 1024 -m /models/model.gguf
```

验证方式：`docker build` 走完所有层即为构建成功。

## Architecture

```
llama-openvino-docker/
├── Dockerfile          # Docker 多阶段构建（OpenVINO 后端）
├── README.md           # 项目说明 + 快速开始
└── AGENTS.md           # 本文件
```

### Dockerfile 内部阶段

1. **build** — 安装编译工具链，下载 OpenVINO 2026.2 归档，编译 llama.cpp（`-DGGML_OPENVINO=ON`）
2. **base** — 最小 Ubuntu 24.04 运行时 + Intel GPU 驱动（IGC + Compute Runtime + Level Zero）
3. **full** — base + 所有二进制和 Python 工具
4. **light** — base + 仅 `llama-cli`（默认目标）
5. **server** — base + 仅 `llama-server`，默认 `LLAMA_ARG_CTX_SIZE=8192`

GPU 驱动从 Intel GitHub Releases 下载精确版本，确保 OpenVINO GPU 插件兼容性。

## Docker 构建目标

| 目标 | 说明 |
|------|------|
| `base` | 运行时库 + 最小依赖（OCL-ICD）+ GPU 驱动 |
| `full` | 所有二进制 + Python 工具 |
| `light` | 仅 llama-cli（默认） |
| `server` | 仅 llama-server + health check |

构建命令示例：`docker build --target=light -t llama-openvino:light .`

GPU 透传：`--device=/dev/dri --group-add=$(stat -c "%g" /dev/dri/render* | head -n 1)`
NPU 透传：`--device=/dev/accel`

## Conventions

- **语言**: 中文注释 + 中文用户输出
- **验证**: 构建通过 `docker build`；运行时通过 `--version` 检查
- **GPU 驱动**: 使用 Intel 官方 GitHub Releases，不依赖发行版包管理器

## Notes

（留白供后续补充）
