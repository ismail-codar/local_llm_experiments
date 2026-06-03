docker rm -f local-ai
docker pull localai/localai:latest-gpu-nvidia-cuda-13

docker run -ti --name local-ai \
  -p 8000:8080 \
  --gpus all \
  --ipc=host \
  -e DEBUG=true \
  -e LOCALAI_EXTERNAL_BACKENDS="vllm,llama-cpp" \
  -e HF_TOKEN="$HF_TOKEN" \
  -v "$PWD/models:/models" \
  -v "$PWD/data:/data" \
  -v "$PWD/backends:/backends" \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
  localai/localai:latest-gpu-nvidia-cuda-13