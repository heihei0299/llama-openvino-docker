# llama.cpp 参数参考手册

> 适用版本：llama.cpp (OpenVINO 后端) — 持续更新

---

## 一、模型加载

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-m, --model <路径>` | — | **模型文件路径**。GGUF 格式，如 `-m /models/model.gguf` |
| `-hfr, --hf-repo <用户>/<模型>[:量化]` | — | 从 Hugging Face 自动下载模型，如 `-hfr ggml-org/GLM-4.7-Flash-GGUF:Q4_K_M` |
| `--no-warmup` | 关闭 | **跳过预热**。首次推理不额外跑几轮热身，减少首 token 延迟 |
| `-ngl, --n-gpu-layers <N>` | `-1` | **GPU 卸载层数**。`-1`=全部在 GPU，`0`=全部在 CPU |
| `-sm, --split-mode <none\|layer\|row\|tensor>` | `layer` | GPU 拆分模式 |
| `-mg, --main-gpu <i>` | `0` | 主 GPU 设备索引 |
| `-ts, --tensor-split <ts0/ts1/..>` | `0` | 多 GPU 张量分配比例 |
| `-nkvo, --no-kv-offload <0\|1>` | `0` | 禁用 KV cache 卸载到 GPU |
| `-mmp, --mmap <0\|1>` | `1` | 启用内存映射加载模型 |
| `-dio, --direct-io <0\|1>` | `0` | 启用直接 IO（绕过页缓存） |

---

## 二、上下文与生成长度

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-c, --ctx-size <N>` | `0` (从模型读取) | **上下文大小**。总 KV cache 容纳的 token 数。越大内存占用越高 |
| `-n, --predict, --n-predict <N>` | `-1` (无限) | **生成 token 数上限**。`-n 256` 则最多生成 256 个 token 后停止 |
| `-b, --batch-size <N>` | `2048` | **逻辑 batch 大小**。影响 prompt 处理阶段的并行度 |
| `-ub, --ubatch-size <N>` | `512` | **物理 batch 大小**。单次 kernel 执行的 batch，受 GPU 内存限制 |
| `--keep <N>` | `0` | **保留初始 prompt 的 token 数**。`-1`=保留全部，用于长对话场景 |
| `--yarn-orig-ctx <N>` | `0` (模型训练值) | YaRN：原始上下文大小，用于扩展超过训练长度的上下文 |
| `--ctx-checkpoints <N>` | 动态 | 每 slot 最大上下文检查点数量 |

> **注意**：`-c 0` 表示从 GGUF 模型文件元数据中读取默认上下文。OpenVINO 后端建议显式设置。  
> 在 `llama-server` 中，每 slot 可用上下文 = `-c / -np`。

---

## 三、推理线程与性能

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-t, --threads <N>` | 系统自动 | **CPU 线程数**。用于 prompt 处理和 token 生成 |
| `-tb, --threads-batch <N>` | 同 `-t` | **batch 处理线程数**。可单独设置优化 CPU 利用率 |
| `-C, --cpu-mask <十六进制>` | `0x0` | **CPU 亲和性掩码**。绑定线程到指定核心，减少上下文切换 |
| `-Cr, --cpu-range <lo-hi>` | — | CPU 范围绑定 |
| `-Cb, --cpu-mask-batch <M>` | 同 `-C` | batch 阶段的 CPU 掩码 |
| `-Crb, --cpu-range-batch <lo-hi>` | — | batch 阶段的 CPU 范围 |
| `--cpu-strict <0\|1>` | `0` | 严格 CPU 亲和性 |
| `--cpu-strict-batch <0\|1>` | 同 `--cpu-strict` | batch 阶段严格亲和性 |
| `--prio <0\|1\|2\|3>` | `0` | **线程优先级**：0=normal，1=medium，2=high，3=realtime |
| `--prio-batch <N>` | 同 `--prio` | batch 阶段线程优先级 |
| `--poll <0-100>` | `50` | **轮询等待比例**。100=忙等待，0=完全阻塞等待 |
| `--poll-batch <0\|1>` | 同 `--poll` | batch 阶段轮询模式 |

---

## 四、采样参数（控制生成质量）

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--temp <N>` | `0.8` | **温度**。越高越随机，越低越确定。`0`=贪婪采样 |
| `--top-k <N>` | `40` | 仅从概率最高的 K 个 token 中采样 |
| `--top-p <N>` | `0.9` | **核采样**。累积概率达到 P 的最小 token 集合中采样 |
| `--min-p <N>` | `0.05` | 仅保留概率 ≥ 最可能 token × min_p 的 token |
| `--repeat-penalty <N>` | `1.0` | **重复惩罚**。`>1.0` 抑制重复，`<1.0` 鼓励重复 |
| `--repeat-last-n <N>` | `64` | 重复惩罚考虑的最近 token 数量 |
| `--frequency-penalty <N>` | `0.0` | **频率惩罚**。基于 token 出现频率降低其概率 |
| `--presence-penalty <N>` | `0.0` | **存在惩罚**。基于 token 是否出现过降低其概率 |
| `--seed <N>` | `-1` (随机) | **随机种子**。固定种子可复现相同输出 |
| `--samplers <序列>` | `top_k;top_p;min_p;temp` | 采样器执行顺序 |
| `--mirostat <0\|1\|2>` | `0` | Mirostat 采样模式（自适应温度） |
| `--mirostat-lr <N>` | `0.1` | Mirostat 学习率 |
| `--mirostat-ent <N>` | `5.0` | Mirostat 目标困惑度 |

### 采样模式速查

| 场景 | 推荐参数 |
|------|---------|
| **翻译/摘要** | `--temp 0 --top-k 1` |
| **对话/创意** | `--temp 0.8 --top-p 0.9` |
| **代码生成** | `--temp 0.2 --top-p 0.95` |
| **精确问答** | `--temp 0 --top-k 1 --repeat-penalty 1.1` |

---

## 五、注意力与 KV Cache

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-fa, --flash-attn <on\|off\|auto>` | `auto` | **Flash Attention**。加速长上下文推理，减少显存占用 |
| `-ctk, --cache-type-k <t>` | `f16` | **K cache 精度**：`f16`/`q8_0`/`q4_0` |
| `-ctv, --cache-type-v <t>` | `f16` | **V cache 精度**：同上 |
| `--no-kv-offload` | 关闭 | 禁止 KV cache 卸载到 GPU |

---

## 六、服务器特有参数（llama-server）

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-np, --parallel <N>` | `-1` (自动) | **并行 slot 数**。同时处理多少请求，自动值 ≈ CPU 核数 |
| `--host <地址>` | `127.0.0.1` | 监听地址。`0.0.0.0` 接受外部连接 |
| `--port <端口>` | `8080` | HTTP 监听端口 |
| `--slot-save-path <路径>` | — | slot 状态保存路径（用于持久化对话） |
| `--slots, --no-slots` | 启用 | 暴露 slots 监控端点 |
| `--endpoint-slots <0\|1>` | `1` | 启用 slots 端点 |
| `--cache-reuse, --no-cache-reuse` | 自动 | 复用 prompt cache |
| `--cache-idle-slots, --no-cache-idle-slots` | 自动 | 闲置 slot 保存到 prompt cache |
| `--fit-ctx <N>` | `4096` | `--fit` 选项的最小 ctx 值 |
| `-ctxcp, --swa-checkpoints <N>` | 动态 | slot 上下文检查点数量 |
| `--jinja` | 关闭 | 启用 Jinja2 chat template 支持 |

### slot 上下文公式

```
每 slot 可用 token 数 = -c / -np

示例：
  -c 8192 -np 4   → 每 slot 2048 tokens
  -c 4096 -np 2   → 每 slot 2048 tokens
  -c 8192 -np 1   → 单 slot 独占 8192 tokens
```

---

## 七、OpenVINO 特有参数

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `GGML_OPENVINO_DEVICE` | `CPU` | **目标设备**：`CPU` / `GPU` / `NPU` / `GPU.0` |
| `GGML_OPENVINO_STATEFUL_EXECUTION` | `0` | **状态化 KV 缓存**（GPU 强烈推荐设为 `1`） |
| `GGML_OPENVINO_CACHE_DIR` | 未设置 | 模型编译缓存目录，避免每次重启重复编译 |
| `GGML_OPENVINO_PREFILL_CHUNK_SIZE` | `256` | NPU 预填分块大小（仅 NPU） |
| `GGML_OPENVINO_DISABLE_CACHE` | `0` | 禁用进程内编译模型缓存 |
| `GGML_OPENVINO_DISABLE_KV_SLICE` | `0` | 禁用 KV 缓存输入张量切片 |
| `GGML_OPENVINO_MANUAL_GQA_ATTN` | 设备相关 | 手动 GQA 注意力控制 |
| `GGML_OPENVINO_PROFILING` | `0` | 启用执行性能分析 |
| `GGML_OPENVINO_DUMP_CGRAPH` | `0` | 导出 GGML 计算图到 `cgraph_ov.txt` |
| `GGML_OPENVINO_DUMP_IR` | `0` | 序列化 OpenVINO IR 文件 |
| `GGML_OPENVINO_DEBUG_INPUT` | `0` | 调试输入张量 |
| `GGML_OPENVINO_DEBUG_OUTPUT` | `0` | 调试输出张量 |

> 布尔值约定：设为正整数 `1` 启用；未设、空值、`0`、负数视为禁用。

### 设备选择指南

| 设备 | 环境变量 | 推荐场景 |
|------|---------|---------|
| CPU | `GGML_OPENVINO_DEVICE=CPU` | 兼容性最佳，内存充足 |
| GPU | `GGML_OPENVINO_DEVICE=GPU` | 需要高性能 prompt 处理 |
| NPU | `GGML_OPENVINO_DEVICE=NPU` | 低功耗推理，需限制 `-c 512` |

---

## 八、Benchmark 参数（llama-bench）

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-p, --n-prompt <N>` | `512` | prompt 长度 |
| `-n, --n-gen <N>` | `128` | 生成长度 |
| `-r, --repetitions <N>` | `5` | 重复测试次数 |
| `-o, --output <格式>` | `md` | 输出格式：`csv`/`json`/`md` |
| `-fa, --flash-attn` | `auto` | Flash Attention（bench 必须传 `-fa 1`） |
| `--no-warmup` | 关闭 | 跳过预热 |

---

## 九、Docker 环境变量覆盖

llama-server 支持通过环境变量覆盖命令行参数：

| 环境变量 | 对应参数 |
|----------|---------|
| `LLAMA_ARG_CTX_SIZE` | `-c, --ctx-size` |
| `LLAMA_ARG_N_PARALLEL` | `-np, --parallel` |
| `LLAMA_ARG_HOST` | `--host` |
| `LLAMA_ARG_PORT` | `--port` |
| `LLAMA_ARG_BATCH` | `-b, --batch-size` |
| `LLAMA_ARG_UBATCH` | `-ub, --ubatch-size` |
| `LLAMA_ARG_THREADS` | `-t, --threads` |
| `LLAMA_ARG_N_PREDICT` | `-n, --predict` |
| `LLAMA_ARG_FLASH_ATTN` | `-fa, --flash-attn` |
| `LLAMA_ARG_FIT_CTX` | `-fitc, --fit-ctx` |
| `LLAMA_ARG_YARN_ORIG_CTX` | `--yarn-orig-ctx` |
| `LLAMA_ARG_CACHE_IDLE_SLOTS` | `--cache-idle-slots` |
| `LLAMA_ARG_CTX_CHECKPOINTS` | `-ctxcp, --ctx-checkpoints` |
| `LLAMA_ARG_ENDPOINT_SLOTS` | `--slots` |

> Docker 镜像 `llama-openvino-docker:server` 预设了 `LLAMA_ARG_CTX_SIZE=8192` 和 `LLAMA_ARG_HOST=0.0.0.0`。传 `-c` 参数会覆盖环境变量。

---

## 十、常用组合速查

```bash
# 1. CPU 推理
llama-cli -m model.gguf -c 2048 --temp 0 -n 256 --no-warmup

# 2. GPU 推理（OpenVINO）
GGML_OPENVINO_DEVICE=GPU \
GGML_OPENVINO_STATEFUL_EXECUTION=1 \
llama-cli -m model.gguf -c 2048 --temp 0 -n 256 -fa 1

# 3. API 服务器（4 slots，每 slot 2048 context）
llama-server -m model.gguf -c 8192 -np 4 --host 0.0.0.0 --port 8080

# 4. 翻译场景（确定性输出，小上下文）
llama-cli -m model.gguf -c 512 --temp 0 -n 256 --no-warmup \
    --prompt "Translate: Hello world"

# 5. 高并发翻译服务器
llama-server -m model.gguf -c 8192 -np 4 --temp 0 -n 256 \
    --host 0.0.0.0 --port 8080

# 6. Docker GPU 服务器
docker run --rm -it -p 8080:8080 -v ~/models:/models \
    --device=/dev/dri \
    --group-add=$(stat -c "%g" /dev/dri/render* | head -n 1) \
    -u $(id -u):$(id -g) \
    --env=GGML_OPENVINO_DEVICE=GPU \
    ghcr.io/heihei0299/llama-openvino-docker:server \
    --no-warmup -c 8192 -m /models/model.gguf --host 0.0.0.0
```

---

## 附：LLM 推理术语说明

| 术语 | 说明 |
|------|------|
| **Token** | 文本的最小单位，中文约 1.5-2 字/token，英文约 0.75 词/token |
| **Prompt** | 输入给模型的文本 |
| **Context** | 模型能"看到"的总 token 数（prompt + 已生成内容） |
| **KV Cache** | 注意力机制的键值缓存，显存占用随上下文线性增长 |
| **Batch** | 一次前向传播处理的 token 数。`batch=prompt 长度` 时一次跑完 prompt |
| **Quantization** | 模型量化（如 Q4_K_M），用更少比特表示权重，缩小模型体积 |
| **Flash Attention** | 一种高效注意力实现，减少 KV cache 读写量 |
| **Slot** | 服务器中独立处理请求的上下文单元 |
