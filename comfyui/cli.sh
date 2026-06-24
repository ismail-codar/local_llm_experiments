#!/bin/sh
# Krea-2-Turbo yerel servis kontrol: ComfyUI backend + Gradio onyuz.
# start / stop / status / log [comfy|app].  POSIX sh — hedef: GPU'lu Linux
# makinesi (Git Bash MINGW64'te de calisir).
#
# ComfyUI : 127.0.0.1:8188  (yalnizca yerel, dogrudan disa acilmaz)
# Gradio  : 0.0.0.0:8012    (Caddy /krea subpath'i -> bkz. caddy-server/Caddyfile)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMFY_DIR="$SCRIPT_DIR/ComfyUI"
COMFY_VENV="$COMFY_DIR/.venv"
APP_VENV="$SCRIPT_DIR/.venv"

COMFY_HOST="127.0.0.1"
COMFY_PORT="${COMFYUI_PORT:-8188}"
APP_HOST="${GRADIO_SERVER_NAME:-0.0.0.0}"
APP_PORT="${GRADIO_SERVER_PORT:-8012}"
ROOT_PATH="${GRADIO_ROOT_PATH:-/krea}"

COMFY_PID="$SCRIPT_DIR/comfyui.pid"
APP_PID="$SCRIPT_DIR/app.pid"
COMFY_LOG="$SCRIPT_DIR/comfyui.log"
APP_LOG="$SCRIPT_DIR/app.log"

# uv venv: Windows (Git Bash) -> .venv/Scripts/python, Linux -> .venv/bin/python
venv_py() {
  if [ -x "$1/Scripts/python.exe" ]; then echo "$1/Scripts/python.exe";
  elif [ -x "$1/bin/python" ]; then echo "$1/bin/python";
  else echo ""; fi
}

is_running() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

start() {
  COMFY_PY="$(venv_py "$COMFY_VENV")"
  APP_PY="$(venv_py "$APP_VENV")"
  [ -n "$COMFY_PY" ] || { echo "ComfyUI venv yok. Once ./install.sh"; exit 1; }
  [ -n "$APP_PY" ] || { echo "Gradio venv yok. Once ./install.sh"; exit 1; }

  if is_running "$COMFY_PID"; then
    echo "ComfyUI zaten calisiyor (PID $(cat "$COMFY_PID"))."
  else
    echo "ComfyUI baslatiliyor -> $COMFY_HOST:$COMFY_PORT ..."
    cd "$COMFY_DIR"
    nohup "$COMFY_PY" main.py --listen "$COMFY_HOST" --port "$COMFY_PORT" \
      > "$COMFY_LOG" 2>&1 &
    echo $! > "$COMFY_PID"
    echo "  PID $(cat "$COMFY_PID"). Log: $COMFY_LOG"
  fi

  if is_running "$APP_PID"; then
    echo "Gradio zaten calisiyor (PID $(cat "$APP_PID"))."
  else
    echo "Gradio baslatiliyor -> $APP_HOST:$APP_PORT (root_path=$ROOT_PATH) ..."
    cd "$SCRIPT_DIR"
    GRADIO_SERVER_NAME="$APP_HOST" \
    GRADIO_SERVER_PORT="$APP_PORT" \
    GRADIO_ROOT_PATH="$ROOT_PATH" \
    COMFYUI_URL="http://$COMFY_HOST:$COMFY_PORT" \
      nohup "$APP_PY" app.py > "$APP_LOG" 2>&1 &
    echo $! > "$APP_PID"
    echo "  PID $(cat "$APP_PID"). Log: $APP_LOG"
  fi
  echo "Caddy uzerinden erisim: http://localhost:7999/krea/"
}

stop_one() {
  # $1=pidfile $2=isim
  if ! is_running "$1"; then
    echo "$2 calismiyor."
    rm -f "$1"
    return 0
  fi
  PID="$(cat "$1")"
  echo "$2 durduruluyor (PID $PID)..."
  kill "$PID" 2>/dev/null || true
  for _ in $(seq 1 30); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
  kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null || true
  rm -f "$1"
}

stop() { stop_one "$APP_PID" "Gradio"; stop_one "$COMFY_PID" "ComfyUI"; }

status() {
  is_running "$COMFY_PID" && echo "ComfyUI calisiyor (PID $(cat "$COMFY_PID")) -> $COMFY_HOST:$COMFY_PORT" || echo "ComfyUI calismiyor."
  is_running "$APP_PID"   && echo "Gradio  calisiyor (PID $(cat "$APP_PID")) -> $APP_HOST:$APP_PORT$ROOT_PATH" || echo "Gradio calismiyor."
}

log() {
  case "${1:-app}" in
    comfy|comfyui) tail -n 255 -f "$COMFY_LOG" ;;
    *)             tail -n 255 -f "$APP_LOG" ;;
  esac
}

case "$1" in
  start)  start ;;
  stop)   stop ;;
  status) status ;;
  log)    shift; log "$@" ;;
  *) echo "Kullanim: $0 {start|stop|status|log [comfy|app]}"; exit 1 ;;
esac
