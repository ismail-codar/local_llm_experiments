```sh
curl http://10.198.15.173:8000/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{
    "model": "embeddinggemma-300m-GGUF",
    "input": "Merhaba dünya"
  }'
```
---
```sh
curl http://10.198.15.173:8000/v1/chat/completions\
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3.6-35B-A3B-MTP-GGUF",
    "messages": [
      {
        "role": "user",
        "content": "Merhaba dünya!"
      }
    ]
  }'
```
---
izle
```sh
watch -n 2 "grep -E 'eth0|ens|enp' /proc/net/dev"
watch -n 5 'docker ps -s --filter name=local-ai --format "{{.Size}}"'
watch -n 2 'du -h --max-depth=1 ~/.cache/huggingface/hub | sort -h'
sudo lsof -Pan -iTCP -sTCP:LISTEN | grep -i vllm
ps aux | grep -i '[v]llm'
pkill -f "vllm"
grep -i vllm
```

vllm serve Qwen/Qwen3.6-35B-A3B-FP8 \
  --speculative-config '{"method": "dflash", "model": "z-lab/Qwen3.6-35B-A3B-DFlash", "num_speculative_tokens": 15}' \
  --attention-backend flash_attn \
  --max-num-batched-tokens 32768 \
  --port 8000


docker exec -it local-ai bash

/backends/cuda13-vllm/venv/bin/python -c "import vllm; print(vllm.__version__); print(vllm.__file__)"
/backends/cuda13-vllm/venv/bin/python -c "from vllm.transformers_utils.tokenizer import get_tokenizer; print('OK')"