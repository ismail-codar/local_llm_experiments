#!/bin/sh
# Krea-2-Turbo yerel kurulum: ComfyUI + RealRebelAI krea2 GGUF node + agirliklar
# + Gradio onyuz venv'i. POSIX sh — hedef: GPU'lu Linux makinesi
# (Git Bash MINGW64'te de calisir). Gerektirir: git, uv, python3.12, curl.
#
# Kullanim:
#   ./install.sh            # her sey: comfyui + node + venv'ler + agirliklar
#   ./install.sh comfyui    # sadece ComfyUI klonla + venv + torch + requirements
#   ./install.sh node       # sadece krea2 custom node
#   ./install.sh app        # sadece Gradio onyuz venv'i
#   ./install.sh weights     # sadece model dosyalarini indir (resume destekli)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMFY_DIR="$SCRIPT_DIR/ComfyUI"
COMFY_VENV="$COMFY_DIR/.venv"
APP_VENV="$SCRIPT_DIR/.venv"

HF="https://huggingface.co"

install_comfyui() {
  if [ ! -d "$COMFY_DIR/.git" ]; then
    echo ">> ComfyUI klonlaniyor..."
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI "$COMFY_DIR"
  else
    echo ">> ComfyUI mevcut, atlandi."
  fi

  echo ">> ComfyUI venv (uv) + torch + requirements..."
  uv venv --python 3.12 "$COMFY_VENV"

  # GPU varsa CUDA torch, yoksa CPU (CPU'da bu DiT modeli ÇOK yavas calisir).
  if command -v nvidia-smi >/dev/null 2>&1 || [ -f "/c/Windows/System32/nvidia-smi.exe" ]; then
    echo "   NVIDIA tespit edildi -> CUDA (cu124) torch"
    TORCH_INDEX="https://download.pytorch.org/whl/cu124"
  else
    echo "   !! NVIDIA YOK -> CPU torch. Uyari: 8.8GB DiT modeli CPU'da cok yavas/RAM-yogun."
    TORCH_INDEX="https://download.pytorch.org/whl/cpu"
  fi
  uv pip install --python "$COMFY_VENV" torch torchvision torchaudio --index-url "$TORCH_INDEX"
  uv pip install --python "$COMFY_VENV" -r "$COMFY_DIR/requirements.txt"
}

install_node() {
  NODE_DIR="$COMFY_DIR/custom_nodes/ComfyUI-GGUF_KREA-2"
  if [ ! -d "$NODE_DIR/.git" ]; then
    echo ">> krea2 GGUF custom node klonlaniyor..."
    git clone --depth 1 https://github.com/RealRebelAI/ComfyUI-GGUF_KREA-2 "$NODE_DIR"
  else
    echo ">> krea2 node mevcut, atlandi."
  fi
  if [ -f "$NODE_DIR/requirements.txt" ]; then
    uv pip install --python "$COMFY_VENV" -r "$NODE_DIR/requirements.txt"
  else
    # En azindan gguf okuyucu gerekli
    uv pip install --python "$COMFY_VENV" gguf
  fi
}

install_app() {
  echo ">> Gradio onyuz venv'i..."
  uv venv --python 3.12 "$APP_VENV"
  uv pip install --python "$APP_VENV" -r "$SCRIPT_DIR/requirements.txt"
}

# $1=url  $2=hedef dosya
dl() {
  if [ -f "$2" ]; then
    echo "   var, atlandi: $(basename "$2")"
    return 0
  fi
  echo "   indiriliyor: $(basename "$2")"
  curl -L -C - --fail -o "$2.part" "$1"
  mv "$2.part" "$2"
}

download_weights() {
  echo ">> Model dosyalari (resume destekli)..."
  mkdir -p "$COMFY_DIR/models/unet" "$COMFY_DIR/models/text_encoders" "$COMFY_DIR/models/vae"

  # 1) GGUF unet (~8.8 GB) -> models/unet
  dl "$HF/realrebelai/KREA-2_GGUFs/resolve/main/TURBO/Krea-2-Turbo-Q5_K_S.gguf" \
     "$COMFY_DIR/models/unet/Krea-2-Turbo-Q5_K_S.gguf"

  # 2) Qwen3-VL-4B fp8 text encoder -> models/text_encoders
  dl "$HF/Comfy-Org/Qwen3-VL/resolve/main/text_encoders/qwen3vl_4b_fp8_scaled.safetensors" \
     "$COMFY_DIR/models/text_encoders/qwen3vl_4b_fp8_scaled.safetensors"

  # 3) Qwen Image VAE -> models/vae
  dl "$HF/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors" \
     "$COMFY_DIR/models/vae/qwen_image_vae.safetensors"

  echo ">> Agirliklar tamam."
}

case "${1:-all}" in
  comfyui) install_comfyui ;;
  node)    install_node ;;
  app)     install_app ;;
  weights) download_weights ;;
  all)
    install_comfyui
    install_node
    install_app
    download_weights
    echo ""
    echo "Kurulum tamam. Baslat: ./cli.sh start"
    ;;
  *) echo "Kullanim: $0 {all|comfyui|node|app|weights}"; exit 1 ;;
esac
