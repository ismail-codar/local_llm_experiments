#!/bin/sh
set -e

echo "=== llama-swap baslatici (coklu model + routing + llama-ui) ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
SWAP_BIN="$ROOT_DIR/bin/llama-swap"
CONFIG="$ROOT_DIR/swap.yaml"
LOG_FILE="$ROOT_DIR/llama-swap.log"

# Disa acik servis adresi (llama-swap'in dinleyecegi port)
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8001}"

# Opsiyonel: API anahtari. Bos birakirsan kimlik dogrulama yok.
# Bu degerler swap.yaml icindeki apiKeys listesine de eklenebilir;
# burada CLI uzerinden gecmek ihtiyaca gore secilebilir.
API_KEY="${API_KEY:-}"

if [ ! -x "$SWAP_BIN" ]; then
    echo "llama-swap binary'si yok:"
    echo "   $SWAP_BIN"
    echo "Once ./install-swap.sh calistir."
    exit 1
fi

if [ ! -f "$CONFIG" ]; then
    echo "Config bulunamadi: $CONFIG"
    exit 1
fi

: > "$LOG_FILE"

set --
set -- "$@" --config "$CONFIG"
set -- "$@" --listen "$HOST:$PORT"
if [ -n "$API_KEY" ]; then
    # API_KEY ortam degiskenini swap.yaml icinden ${env.API_KEY} ile referans verebilirsin.
    export API_KEY
fi

nohup "$SWAP_BIN" "$@" > "$LOG_FILE" 2>&1 &
SWAP_PID=$!

IP_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "$IP_ADDR" ] && IP_ADDR="127.0.0.1"

echo ""
echo "llama-swap arka planda baslatildi (PID: $SWAP_PID)"
echo "Log dosyasi: $LOG_FILE"
echo "Config     : $CONFIG"
echo ""
echo "Tek giris (proxy + WebUI):"
echo "   http://$IP_ADDR:$PORT/"
echo ""
echo "OpenAI uyumlu endpoint:"
echo "   base_url = http://$IP_ADDR:$PORT/v1"
echo "   model    = qwen3.6-35b-mtp   (alias: qwen3.6 | qwen)"
echo ""
echo "Model listesi:"
echo "   curl -s http://$IP_ADDR:$PORT/v1/models | jq"
echo ""
echo "Log takip:"
echo "   tail -f $LOG_FILE"
echo ""
echo "Durdurmak icin:"
echo "   kill $SWAP_PID"
