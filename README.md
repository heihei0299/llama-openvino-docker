# llama-openvino-docker

llama.cpp + OpenVINO 后端 — 针对 Intel CPU/GPU/NPU 极致优化的 Docker 方案。

严格参照官方文档：[llama.cpp OpenVINO Backend](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENVINO.md)

---

## 快速开始（使用预编译镜像）

GitHub Actions 自动构建并推送镜像到 GitHub Container Registry，无需本地编译即可使用。

```bash
# 1. 拉取镜像
docker pull ghcr.io/heihei0299/llama-openvino-docker:light
docker pull ghcr.io/heihei0299/llama-openvino-docker:server

# 2. 下载模型
mkdir -p ~/models/
wget https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf \
     -O ~/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf

# 3. CPU 模式运行
docker run --rm -it -v ~/models:/models \
    ghcr.io/heihei0299/llama-openvino-docker:light \
    --no-warmup -c 1024 -m /models/Llama-3.2-1B-Instruct-Q4_K_M.gguf

# 4. GPU 模式运行
docker run --rm -it -v ~/models:/models \
    --device=/dev/dri \
    --group-add=$(stat -c "%g" /dev/dri/render* | head -n 1) \
    -u $(id -u):$(id -g) \
    --env=GGML_OPENVINO_DEVICE=GPU \
    --env=GGML_OPENVINO_STATEFUL_EXECUTION=1 \
    ghcr.io/heihei0299/llama-openvino-docker:light \
    --no-warmup -c 1024 -m /models/Llama-3.2-1B-Instruct-Q4_K_M.gguf

# 5. API 服务器模式
docker run --rm -it -p 8080:8080 -v ~/models:/models \
    ghcr.io/heihei0299/llama-openvino-docker:server \
    --no-warmup -c 8192 -m /models/Llama-3.2-1B-Instruct-Q4_K_M.gguf --host 0.0.0.0
```

可用镜像标签：

| 标签 | 说明 |
|------|------|
| `:latest` | 最新版 CLI（指向 light） |
| `:light` | 仅 llama-cli（CPU/GPU/NPU） |
| `:server` | llama-server + health check（API 服务） |
| `:base` | 仅运行时库 |

> 预编译镜像使用 Ubuntu 24.04，集成 Intel GPU 驱动（IGC + Compute Runtime + Level Zero）。
> 如需自定义编译参数或验证构建过程，请参考下方「本地构建」章节。

---

## 特性

- **Intel CPU 极致优化** — OpenVINO 后端，充分利用 Intel CPU 的 AVX/VNNI 指令集
- **跨设备支持** — 同一套方案覆盖 Intel CPU / GPU / NPU
- **零依赖运行** — 编译后无需 Python 环境
- **Docker 容器化** — 基于 Ubuntu 24.04 的多阶段构建

---

## 1. 构建

### 本地构建

**前置要求**：确保 Docker 已安装且当前用户有权限使用：
```bash
# 如果遇到权限错误，将用户加入 docker 组
sudo usermod -aG docker $USER
# 重新登录后生效
```

```bash
# 基础运行时镜像
docker build --target=base -t llama-openvino:base .

# 完整镜像（所有二进制）
docker build --target=full -t llama-openvino:full .

# 最小 CLI 镜像（仅 llama-cli）
docker build --target=light -t llama-openvino:light .

# 服务器镜像（仅 llama-server + health check）
docker build --target=server -t llama-openvino:server .

# 默认 CLI 镜像（也可以直接构建）
docker build -t llama-openvino:latest .
```

---

## 2. 下载示例模型

创建模型目录并下载 Llama-3.2-1B-Instruct（Q4_K_M 量化，约 0.7 GB）：

```bash
# Linux 主机
mkdir -p ~/models/
wget https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf \
     -O ~/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf
```

其他已验证模型见[官方文档](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENVINO.md#validated-models)。

---

## 3. 运行

### Docker 运行

将模型文件保存到 `~/models/` 后挂载到容器：

#### CPU 模式（默认）
```bash
docker run --rm -it -v ~/models:/models llama-openvino:light \
    --no-warmup -c 1024 -m /models/Llama-3.2-1B-Instruct-Q4_K_M.gguf
```

#### Intel GPU 加速

> **前置要求**：宿主机需要安装 Intel GPU 驱动并确保 OpenCL / Level Zero 可用。
> 先验证宿主机：
> ```bash
> # 步骤 1: 检查 Intel GPU 设备是否存在
> ls -la /dev/dri/
>
> # 步骤 2: 检查 Intel GPU OpenCL 是否可用
> sudo apt install clinfo
> clinfo | grep -E "Device Name|Device Version|Driver Version"
>
> # 步骤 3: 检查 Level Zero GPU 驱动（OpenVINO GPU 插件需要）
> ldconfig -p | grep libze_intel_gpu
>
> # 步骤 4: 确认 i915 内核模块已加载
> lsmod | grep i915
> ```
>
> 如果以上检查均有输出，说明 GPU 驱动已正确安装。

```bash
docker run --rm -it -v ~/models:/models \
    --device=/dev/dri \
    --group-add=$(stat -c "%g" /dev/dri/render* | head -n 1) \
    -u $(id -u):$(id -g) \
    --env=GGML_OPENVINO_DEVICE=GPU \
    --env=GGML_OPENVINO_STATEFUL_EXECUTION=1 \
    llama-openvino:light \
    --no-warmup -c 1024 -m /models/Llama-3.2-1B-Instruct-Q4_K_M.gguf
```

如果 GPU 仍然不可用，尝试容器内诊断：
```bash
# 进入容器检查 OpenCL 设备（需要覆盖 entrypoint）
docker run --rm -it --device=/dev/dri \
    --group-add=$(stat -c "%g" /dev/dri/render* | head -n 1) \
    --entrypoint bash \
    llama-openvino:light \
    -c "apt-get update && apt-get install -y clinfo && clinfo | grep -E 'Device Name|Driver Version'"
```

#### Intel NPU 加速
```bash
docker run --rm -it -v ~/models:/models \
    --device=/dev/accel \
    --group-add=$(stat -c "%g" /dev/dri/render* | head -n 1) \
    -u $(id -u):$(id -g) \
    --env=GGML_OPENVINO_DEVICE=NPU \
    llama-openvino:light \
    --no-warmup -c 512 -m /models/Llama-3.2-1B-Instruct-Q4_K_M.gguf
```

#### API 服务器（OpenAI 兼容）
```bash
# CPU
docker run --rm -it -p 8080:8080 -v ~/models:/models llama-openvino:server \
    --no-warmup -c 8192 -m /models/Llama-3.2-1B-Instruct-Q4_K_M.gguf --host 0.0.0.0

# GPU
docker run --rm -it -v ~/models:/models \
    --device=/dev/dri \
    --group-add=$(stat -c "%g" /dev/dri/render* | head -n 1) \
    -u $(id -u):$(id -g) \
    -p 8080:8080 \
    --env=GGML_OPENVINO_DEVICE=GPU \
    llama-openvino:server \
    --no-warmup -c 8192 -m /models/Llama-3.2-1B-Instruct-Q4_K_M.gguf --host 0.0.0.0
```

测试 API：
```bash
curl -f http://localhost:8080/health
curl -X POST "http://localhost:8080/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"messages":[{"role":"user","content":"Write a poem about OpenVINO"}],"max_tokens":100}'
```

---

## 4. 运行时配置

通过环境变量配置 OpenVINO 后端行为：

| 变量 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `GGML_OPENVINO_DEVICE` | String | `CPU` | 目标设备：`CPU` / `GPU` / `NPU`。多 GPU 用 `GPU.0`、`GPU.1` |
| `GGML_OPENVINO_CACHE_DIR` | String | 未设置 | 模型缓存目录（如 `/tmp/ov_cache`）。NPU 不支持 |
| `GGML_OPENVINO_PREFILL_CHUNK_SIZE` | Int | `256` | NPU 预填分块大小（仅 NPU） |
| `GGML_OPENVINO_STATEFUL_EXECUTION` | Bool | `0` | 启用状态化 KV 缓存（CPU/GPU 推荐） |
| `GGML_OPENVINO_DISABLE_CACHE` | Bool | `0` | 禁用进程内编译模型缓存 |
| `GGML_OPENVINO_DISABLE_KV_SLICE` | Bool | `0` | 禁用 KV 缓存输入张量切片 |
| `GGML_OPENVINO_MANUAL_GQA_ATTN` | Bool | 设备相关 | 手动 GQA 注意力控制 |
| `GGML_OPENVINO_PROFILING` | Bool | `0` | 启用执行性能分析 |
| `GGML_OPENVINO_DUMP_CGRAPH` | Bool | `0` | 导出 GGML 计算图到 `cgraph_ov.txt` |
| `GGML_OPENVINO_DUMP_IR` | Bool | `0` | 序列化 OpenVINO IR 文件 |
| `GGML_OPENVINO_DEBUG_INPUT` | Bool | `0` | 调试输入张量 |
| `GGML_OPENVINO_DEBUG_OUTPUT` | Bool | `0` | 调试输出张量 |

> *布尔值约定：设为正整数（如 `1`）启用；未设、空值、`0`、负数视为禁用。*

---

## 5. 已知限制

- **`llama-server` + 状态化执行**: 仅支持单会话/单线程
- **`llama-bench`**: 必须使用 `-fa 1`（flash attention）
- **`llama-cli --context-shift`**: 仅状态化模式关闭时可用
- **NPU**: 默认上下文可能为 131072，建议用 `-c 512` 限制；不支持多序列
- **GPU**: `llama-server -np > 1` 时多请求会合并批处理

详见[官方文档](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENVINO.md#known-limitations)。

---

## 6. 常见问题排查

### 6.1 `Context size has been exceeded`（服务器上下文溢出）

```
E srv decode: Context size has been exceeded. off = 138, n_batch = 1, ret = 1
E srv send_error: task id = 500, error: Context size has been exceeded.
```

**原因**：`llama-server` 按 `-np N`（并行 slot 数）平分上下文。每 slot 可用 tokens = `-c / -np`。  
当 slot 收到的 prompt + 生成 tokens 超过此值时，decode 阶段会报错。

从日志中 slot 数量可反推：
- 4 个 slots（id 0–3）× ~260 tokens → `-c / 4 ≈ 256` → `-c` 约 1024
- 默认 `-np -1`（auto）会根据 CPU 核数自动创建 slots

**解决方式**：

| 方式 | 命令示例 | 说明 |
|------|----------|------|
| 增大 `-c` | `-c 8192` | 4 slots 下每 slot 2048 tokens，满足多数场景 |
| 限制 slot 数 | `-np 2 -c 4096` | 减少并行 slot，每个 slot 获得更多上下文 |
| 同时调整 | `-np 2 -c 8192` | 2 slots 每 slot 4096 tokens，兼顾并发与上下文 |

```bash
# 推荐：Docker 服务器启动（4 核默认 4 slots，每 slot 2048）
docker run --rm -it -p 8080:8080 -v ~/models:/models llama-openvino:server \
    --no-warmup -c 8192 -m /models/Llama-3.2-1B-Instruct-Q4_K_M.gguf --host 0.0.0.0

# 限制并行 slot 数（适合内存受限场景）
docker run --rm -it -p 8080:8080 -v ~/models:/models llama-openvino:server \
    -np 2 -c 4096 --no-warmup -m /models/Llama-3.2-1B-Instruct-Q4_K_M.gguf --host 0.0.0.0
```

> **提示**：Docker 镜像 `llama-openvino:server` 已默认设置 `ENV LLAMA_ARG_CTX_SIZE=8192`，但显式传入 `-c` 会覆盖此默认值。使用本地（非 Docker）构建的 `llama-server` 需手动加 `-c`。

#### 情况二：`off = 0`，KV cache 完全占满

日志表现为 `off = 0` 且伴随多次重试逐步缩小 batch 直到失败：

```
W decode: failed to find a memory slot for batch of size 138
W srv decode: failed to find free space in the KV cache, retrying with smaller batch size, off = 0, n_batch = 256
W decode: failed to find a memory slot for batch of size 128
W srv decode: failed to find free space in the KV cache, retrying with smaller batch size, off = 0, n_batch = 64
... (32 → 16 → 8 → 4 → 2 → 1)
E srv decode: Context size has been exceeded. off = 0, n_batch = 1
```

**原因**：KV cache 被全部 slots 同时占满，新请求连一个 token 的位置都找不到。

与「情况一」的区别：

| | 情况一（`off > 0`） | 情况二（`off = 0`） |
|---|---|---|
| 现象 | 在上下文中间位置溢出 | 从头就找不到空间 |
| 触发条件 | 单个 slot 生成超量 | 全部 slots 同时到达，KV cache 彻底填满 |
| `n_batch` 重试 | 无重试，直接失败 | 从 256 → 1 逐步重试 |
| 典型场景 | 长对话累积 tokens | 高并发短请求（如批处理翻译） |

**解决方式**与情况一相同（增大 `-c` 或减少 `-np`）。以下方式对 `off = 0` 模式尤其有效：

- **限制并发**：`-np 2` 或 `-np 1`（单 slot 模式，完全避免竞争）
- **减小 batch size**：`-b 512` 降低每次处理的批量，减少瞬时 KV cache 压力

---

## 项目结构

```
llama-openvino-docker/
├── Dockerfile          # 🐳 Docker 多阶段构建（Ubuntu 24.04）
├── README.md           # 📖 本文档
└── AGENTS.md           # 📋 AI 辅助记忆文件
```
