# llama-openvino-docker

基于 llama.cpp OpenVINO 后端的 Docker 方案，支持 Intel CPU、GPU 和 NPU。预编译镜像发布到 GHCR。设备参数见 [`PARAMETERS.md`](PARAMETERS.md) 和 [llama.cpp OpenVINO 文档](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENVINO.md)。

## CPU 快速开始

~~~sh
docker pull ghcr.io/heihei0299/llama-openvino-docker:light
mkdir -p ~/models
wget https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf -O ~/models/model.gguf
docker volume create ov_cache
docker run --rm -it -v ~/models:/models -v ov_cache:/tmp/ov_cache ghcr.io/heihei0299/llama-openvino-docker:light --no-warmup -c 2048 -m /models/model.gguf
~~~

## GPU、NPU 与服务器

Intel GPU 需将宿主机 /dev/dri 映射到容器：

~~~sh
docker run --rm -it -v ~/models:/models -v ov_cache:/tmp/ov_cache --device=/dev/dri --group-add=$(stat -c "%g" /dev/dri/render* | head -n 1) -u $(id -u):$(id -g) -e GGML_OPENVINO_DEVICE=GPU -e GGML_OPENVINO_STATEFUL_EXECUTION=1 ghcr.io/heihei0299/llama-openvino-docker:light --no-warmup -c 2048 -m /models/model.gguf
~~~

NPU 需映射 /dev/accel，并使用 -c 512；不支持多序列或编译缓存。

OpenAI 兼容服务器：

~~~sh
docker run --rm -it -p 8080:8080 -v ~/models:/models -v ov_cache:/tmp/ov_cache ghcr.io/heihei0299/llama-openvino-docker:server --no-warmup -c 8192 -m /models/model.gguf --host 0.0.0.0
~~~

检查服务并发送请求：

~~~sh
curl -f http://localhost:8080/health
curl -X POST http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d '{"messages":[{"role":"user","content":"Hello"}],"max_tokens":100}'
~~~

## 镜像与构建

| 标签 | 内容 |
| --- | --- |
| `light` | `llama-cli` |
| `server` | `llama-server` 与 health check |
| `full` | 全部二进制，包含 `llama-bench` |
| `base` | 运行时库 |

~~~sh
docker build --target=light -t llama-openvino:light .
docker build --target=server -t llama-openvino:server .
scripts/tune.sh --device auto --scenario server
~~~

GPU / NPU 需要可用的宿主机驱动。更完整的设备参数和调优说明见 `PARAMETERS.md`；压测脚本为 `scripts/benchmark.sh`。