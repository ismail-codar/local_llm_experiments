#!/bin/sh
# vLLM server control (Qwen3.8-27B / NVIDIA L40S 48 GB):
#   install | patch | verify | start | stop | log | clearlog | status | test
#
# llama-turboquant/cli.sh ile ayni kullanim sozlesmesi:
#   sh ./cli.sh --env ./qwen3.8-27b-l40s.env install
#   sh ./cli.sh --env ./qwen3.8-27b-l40s.env patch
#   sh ./cli.sh --env ./qwen3.8-27b-l40s.env verify
#   sh ./cli.sh --env ./qwen3.8-27b-l40s.env start
#   sh ./cli.sh --env ./qwen3.8-27b-l40s.env log
#   sh ./cli.sh --env ./qwen3.8-27b-l40s.env stop
set -e

echo "=== vLLM / Qwen3.8-27B server control ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

CMD=""
ENV_FILE="${ENV_FILE:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --env|-e)   ENV_FILE="$2"; shift 2 ;;
    --env=*)    ENV_FILE="${1#--env=}"; shift ;;
    install|patch|verify|start|stop|log|clearlog|status|test)
                CMD="$1"; shift ;;
    *)
      echo "Bilinmeyen parametre: $1"
      echo "Usage: $0 {install|patch|verify|start|stop|log|clearlog|status|test} [--env /path/to/.env]"
      exit 1 ;;
  esac
done

# Dizin varsayilanlari .env'den ONCE seed ediliyor; boylece env icinde
# MODEL_DIR=$MODEL_ROOT/... gibi referanslar calisir.
VENV_DIR="${VENV_DIR:-$ROOT_DIR/venv}"
MODEL_ROOT="${MODEL_ROOT:-$ROOT_DIR/../models}"
UPSTREAM_DIR="${UPSTREAM_DIR:-$ROOT_DIR/upstream-syv}"

ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
if [ -f "$ENV_FILE" ]; then
  echo "Ayarlar yukleniyor: $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
else
  echo "UYARI: env dosyasi yok: $ENV_FILE (varsayilanlarla devam ediliyor)"
fi

# Her env kendi PID/LOG dosyasini kullanir -> ayni anda birden fazla profil.
_ENV_TAG="$(basename "$ENV_FILE" | sed 's/\.[^.]*$//')"
[ -n "$_ENV_TAG" ] || _ENV_TAG=default
LOG_FILE="${LOG_FILE:-$ROOT_DIR/vllm-$_ENV_TAG.log}"
PID_FILE="${PID_FILE:-$ROOT_DIR/vllm-$_ENV_TAG.pid}"
PATCH_MARKER="${PATCH_MARKER:-$ROOT_DIR/.patches-applied}"

# ---------------------------------------------------------------------------
# Genel varsayilanlar
# ---------------------------------------------------------------------------
VENV_DIR="${VENV_DIR:-$ROOT_DIR/venv}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
VLLM_VERSION="${VLLM_VERSION:-0.27.1}"
PIP_EXTRA="${PIP_EXTRA:-}"

MODEL_ID="${MODEL_ID:-Qwen/Qwen3.8-27B-FP8}"
MODEL_DIR="${MODEL_DIR:-$MODEL_ROOT/Qwen3.8-27B-FP8}"
DOWNLOAD_MODEL="${DOWNLOAD_MODEL:-1}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen3.8-27b}"

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8010}"
API_KEY="${API_KEY:-}"

MODE="${MODE:-single}"

# ---------------------------------------------------------------------------
# MODE presetleri
#
# Sadece env'de AYARLANMAMIS degiskenleri doldurur; env dosyasindaki acik
# deger her zaman kazanir. VRAM hesaplari README.md "VRAM butcesi" bolumunde.
# ---------------------------------------------------------------------------
case "$MODE" in
  single)
    # Gunluk kullanim: vision acik, 128K context, MTP speculative decode.
    ENABLE_VISION="${ENABLE_VISION:-1}"
    MAX_MODEL_LEN="${MAX_MODEL_LEN:-131072}"
    MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
    GPU_UTIL="${GPU_UTIL:-0.93}"
    KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-fp8}"
    ENABLE_MTP="${ENABLE_MTP:-1}"
    SPEC_TOKENS="${SPEC_TOKENS:-3}"
    CUDAGRAPH_CAPTURE_SIZE="${CUDAGRAPH_CAPTURE_SIZE:-32}"
    ;;
  longctx)
    # Tam native 262144 context. Vision kapali: vLLM'in bellek profillemesi
    # vision acikken dummy max-cozunurluk goruntu ile calisir ve olculen
    # activation peak'i buyuterek KV pool'u kucultur.
    ENABLE_VISION="${ENABLE_VISION:-0}"
    MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"
    MAX_NUM_SEQS="${MAX_NUM_SEQS:-2}"
    GPU_UTIL="${GPU_UTIL:-0.93}"
    KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-fp8}"
    ENABLE_MTP="${ENABLE_MTP:-1}"
    SPEC_TOKENS="${SPEC_TOKENS:-3}"
    CUDAGRAPH_CAPTURE_SIZE="${CUDAGRAPH_CAPTURE_SIZE:-32}"
    ;;
  batch)
    # Throughput: cok eszamanli istek. Speculative decode kapali; ~8 eszamanli
    # kullanicinin ustunde duz batching MTP'yi yener.
    ENABLE_VISION="${ENABLE_VISION:-0}"
    MAX_MODEL_LEN="${MAX_MODEL_LEN:-131072}"
    MAX_NUM_SEQS="${MAX_NUM_SEQS:-64}"
    GPU_UTIL="${GPU_UTIL:-0.95}"
    KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-fp8}"
    ENABLE_MTP="${ENABLE_MTP:-0}"
    SPEC_TOKENS="${SPEC_TOKENS:-0}"
    CUDAGRAPH_CAPTURE_SIZE="${CUDAGRAPH_CAPTURE_SIZE:-64}"
    ;;
  *)
    echo "HATA: bilinmeyen MODE=$MODE (single|longctx|batch)"
    exit 1 ;;
esac

MAMBA_SSM_CACHE_DTYPE="${MAMBA_SSM_CACHE_DTYPE-float16}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-2048}"
ATTENTION_BACKEND="${ATTENTION_BACKEND:-}"
ASYNC_SCHEDULING="${ASYNC_SCHEDULING:-1}"
API_SERVER_COUNT="${API_SERVER_COUNT:-1}"
CUSTOM_OPS="${CUSTOM_OPS-+rms_norm,+silu_and_mul}"
ENFORCE_EAGER="${ENFORCE_EAGER:-0}"
DRAFT_SAMPLE_METHOD="${DRAFT_SAMPLE_METHOD:-probabilistic}"

REASONING_PARSER="${REASONING_PARSER-qwen3}"
ENABLE_TOOLS="${ENABLE_TOOLS:-1}"
TOOL_CALL_PARSER="${TOOL_CALL_PARSER-qwen3_coder}"
CHAT_TEMPLATE_FILE="${CHAT_TEMPLATE_FILE:-}"
OVERRIDE_GENERATION_CONFIG="${OVERRIDE_GENERATION_CONFIG:-}"

PREFIX_CACHING="${PREFIX_CACHING:-}"
SWAP_SPACE="${SWAP_SPACE:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
FLASHINFER_SAMPLER="${FLASHINFER_SAMPLER:-}"
GPU_FREE_WAIT="${GPU_FREE_WAIT:-1}"
GPU_FREE_MIB="${GPU_FREE_MIB:-1024}"
GPU_FREE_TIMEOUT="${GPU_FREE_TIMEOUT:-180}"

# syv-ai upstream patch'leri (vLLM 0.27.1 icin yazilmis).
UPSTREAM_PATCH_REPO="${UPSTREAM_PATCH_REPO:-https://github.com/syv-ai/qwen38-27b-rtx3090.git}"
UPSTREAM_DIR="${UPSTREAM_DIR:-$ROOT_DIR/upstream-syv}"
PATCH_SET="${PATCH_SET-vllm-pr50021-gdn-spec-bounds}"

VLLM_BIN="$VENV_DIR/bin/vllm"
HELP_CACHE="$ROOT_DIR/.vllm-serve-help.txt"

# ---------------------------------------------------------------------------
# Yardimcilar
# ---------------------------------------------------------------------------
site_vllm_dir() {
  "$VENV_DIR/bin/python" -c 'import vllm,os;print(os.path.dirname(vllm.__file__))' 2>/dev/null
}

vllm_version() {
  "$VENV_DIR/bin/python" -c 'import vllm;print(vllm.__version__)' 2>/dev/null
}

# "vllm serve --help" torch'u import ettigi icin yavas; bir kez cache'liyoruz.
# Cache, kurulu vllm surumu degistiginde otomatik yenilenir.
build_help_cache() {
  _want="$(vllm_version)"
  if [ -s "$HELP_CACHE" ] && [ "$(head -n1 "$HELP_CACHE")" = "# vllm $_want" ]; then
    return 0
  fi
  echo "vllm serve --help cache'i olusturuluyor (bir kerelik, ~10-30s)..."
  {
    echo "# vllm $_want"
    "$VLLM_BIN" serve --help 2>&1 || true
  } > "$HELP_CACHE"
}

check_flag_supported() {
  # $1: "--flag". Cache'lenmis "vllm serve --help" ciktisinda arar.
  [ -s "$HELP_CACHE" ] || return 0   # cache yoksa engellemeyelim
  grep -q -- "$1" "$HELP_CACHE"
}

gpu_used_mib() {
  nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits \
    -i "${CUDA_VISIBLE_DEVICES%%,*}" 2>/dev/null | head -n1 | tr -d ' '
}

# GOTCHA: vLLM bos VRAM'i baslangicta BIR KEZ olcer. Onceki surec hala VRAM
# birakiyorsa cache pool ~%40 kucuk cikar; sunucu sorunsuz calisir, throughput
# sessizce kotu olur ve oyle kalir. Bu yuzden GPU gercekten bosalana kadar
# bekliyoruz.
wait_for_free_gpu() {
  [ "$GPU_FREE_WAIT" = "1" ] || return 0
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "UYARI: nvidia-smi yok; GPU bosluk kontrolu atlandi."
    return 0
  fi

  _i=0
  while [ "$_i" -lt "$GPU_FREE_TIMEOUT" ]; do
    _used="$(gpu_used_mib)"
    case "$_used" in
      ''|*[!0-9]*) echo "UYARI: GPU kullanimi okunamadi; kontrol atlandi."; return 0 ;;
    esac
    if [ "$_used" -le "$GPU_FREE_MIB" ]; then
      echo "GPU bos (kullanilan: ${_used} MiB <= esik ${GPU_FREE_MIB} MiB)"
      return 0
    fi
    if [ "$_i" = "0" ]; then
      echo "GPU'nun bosalmasi bekleniyor (kullanilan: ${_used} MiB, esik ${GPU_FREE_MIB} MiB)..."
    fi
    sleep 1
    _i=$((_i + 1))
  done

  echo "HATA: GPU ${GPU_FREE_TIMEOUT}s icinde bosalmadi (kullanilan: $(gpu_used_mib) MiB)."
  echo "      Kirli GPU uzerine baslamak KV pool'u kalici olarak kucultur."
  echo "      Once eski sureci durdur. Bilerek gecmek icin: GPU_FREE_WAIT=0"
  exit 1
}

resolve_model_path() {
  if [ "$DOWNLOAD_MODEL" = "1" ]; then
    echo "$MODEL_DIR"
  else
    echo "$MODEL_ID"
  fi
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
install() {
  echo "=== Kurulum ==="
  echo "venv:  $VENV_DIR"
  echo "vLLM:  $VLLM_VERSION"
  echo "Model: $MODEL_ID -> $MODEL_DIR"

  if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "HATA: $PYTHON_BIN bulunamadi."
    exit 1
  fi

  if [ ! -x "$VENV_DIR/bin/python" ]; then
    echo "venv olusturuluyor..."
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  else
    echo "venv zaten var, olusturma atlandi."
  fi

  "$VENV_DIR/bin/pip" install --upgrade pip wheel
  # ninja: flashinfer attention kernel'lerinin JIT derlemesi icin gerekli.
  # shellcheck disable=SC2086
  "$VENV_DIR/bin/pip" install "vllm==$VLLM_VERSION" huggingface_hub hf_transfer ninja $PIP_EXTRA

  echo "Kurulan vLLM: $(vllm_version)"
  rm -f "$HELP_CACHE"

  if [ "$DOWNLOAD_MODEL" = "1" ]; then
    if [ -f "$MODEL_DIR/config.json" ]; then
      echo "Model zaten var, indirme atlandi: $MODEL_DIR"
    else
      echo "Model indiriliyor (~31 GB, disk ihtiyaci ~35 GB)..."
      mkdir -p "$MODEL_DIR"
      HF_HUB_ENABLE_HF_TRANSFER=1 "$VENV_DIR/bin/hf" download "$MODEL_ID" --local-dir "$MODEL_DIR"
    fi
  else
    echo "DOWNLOAD_MODEL=0; model calistirma aninda HF cache'ten cozulecek."
  fi

  echo ""
  echo "Kurulum bitti. Sirada:"
  if [ -n "$PATCH_SET" ]; then
    echo "  sh $0 --env $ENV_FILE patch     # $PATCH_SET"
  fi
  echo "  sh $0 --env $ENV_FILE verify"
  echo "  sh $0 --env $ENV_FILE start"
}

# ---------------------------------------------------------------------------
# patch
#
# syv-ai/qwen38-27b-rtx3090 patch'lerini kurulu vllm paketine uygular.
#
# Varsayilan set sadece vllm-pr50021-gdn-spec-bounds: DeltaNet speculative
# decode kernel'lerindeki bounds check'ler. Upstream PR #50021 HALA ACIK
# (merge edilmedi) ve eszamanli MTP isteklerinde illegal-memory-access
# aliniyor -> MTP kullanacaksan bu patch pratikte gerekli.
#
# Opsiyonel ekleyebilecekler (PATCH_SET'e bosluk ile ekle):
#   speed-knobs-envs sampler-small-topk-fast-softmax   -> sampler hizlandirma
#   spec-decode-attn                                   -> SADECE bf16 KV ile
#
# FP8 checkpoint icin ANLAMSIZ olanlar (uygulamayin):
#   marlin-int8-*        -> yalniz W4A16/AutoRound Marlin yolunu ilgilendirir
#   qwen3_5-embed-quant  -> yalniz int-quantize edilmis embedding tablosu icin
# ---------------------------------------------------------------------------
patch_vllm() {
  if [ -z "$PATCH_SET" ]; then
    echo "PATCH_SET bos; uygulanacak patch yok."
    return 0
  fi
  if ! command -v patch >/dev/null 2>&1; then
    echo "HATA: 'patch' komutu yok (apt-get install -y patch)."
    exit 1
  fi
  if [ ! -x "$VENV_DIR/bin/python" ]; then
    echo "HATA: venv yok; once install."
    exit 1
  fi

  _ver="$(vllm_version)"
  if [ "$_ver" != "0.27.1" ]; then
    echo "UYARI: patch'ler vLLM 0.27.1 icin yazildi, kurulu surum: $_ver"
    echo "       Uyusmazsa dry-run reddeder; PATCH_SET= ile tamamen atlayabilirsin."
  fi

  _site="$(site_vllm_dir)"
  if [ -z "$_site" ]; then
    echo "HATA: vllm paketi bulunamadi."
    exit 1
  fi
  echo "Hedef: $_site"

  if [ -d "$UPSTREAM_DIR/.git" ]; then
    echo "Upstream repo guncelleniyor: $UPSTREAM_DIR"
    ( cd "$UPSTREAM_DIR" && git fetch --all --quiet && git pull --ff-only --quiet ) || true
  else
    echo "Upstream repo klonlaniyor: $UPSTREAM_PATCH_REPO"
    git clone --depth 1 "$UPSTREAM_PATCH_REPO" "$UPSTREAM_DIR"
  fi

  : > "$PATCH_MARKER.tmp"
  for _name in $PATCH_SET; do
    _p="$UPSTREAM_DIR/patches/$_name.patch"
    if [ ! -f "$_p" ]; then
      echo "HATA: patch dosyasi yok: $_p"
      rm -f "$PATCH_MARKER.tmp"
      exit 1
    fi
    if patch -p1 -d "$_site" --dry-run --reverse --force --silent < "$_p" >/dev/null 2>&1; then
      echo "  [zaten uygulanmis] $_name"
      echo "$_name" >> "$PATCH_MARKER.tmp"
      continue
    fi
    if ! patch -p1 -d "$_site" --dry-run --silent < "$_p" >/dev/null 2>&1; then
      echo "  [BASARISIZ - dry-run] $_name  (vLLM surumu uyusmuyor olabilir)"
      rm -f "$PATCH_MARKER.tmp"
      exit 1
    fi
    patch -p1 -d "$_site" < "$_p"
    echo "  [uygulandi] $_name"
    echo "$_name" >> "$PATCH_MARKER.tmp"
  done
  mv "$PATCH_MARKER.tmp" "$PATCH_MARKER"

  echo ""
  echo "UYARI: torch.compile cache patch'lerden haberdar DEGIL; kernel/shape"
  echo "       degisikliginden sonra eski graph replay edilip patlayabilir."
  echo "       Patch sonrasi ilk start'i sunun gibi yap:"
  echo "         VLLM_DISABLE_COMPILE_CACHE=1 sh $0 --env $ENV_FILE start"
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
verify() {
  _rc=0

  echo "--- venv / vLLM ---"
  if [ -x "$VENV_DIR/bin/python" ]; then
    echo "  python: $("$VENV_DIR/bin/python" -V 2>&1)"
    echo "  vllm:   $(vllm_version)"
  else
    echo "  HATA: venv yok: $VENV_DIR"
    _rc=1
  fi

  echo "--- patch ---"
  if [ -n "$PATCH_SET" ]; then
    for _name in $PATCH_SET; do
      if [ -f "$PATCH_MARKER" ] && grep -qx "$_name" "$PATCH_MARKER"; then
        echo "  [ok] $_name"
      else
        echo "  [EKSIK] $_name  ->  sh $0 --env $ENV_FILE patch"
        _rc=1
      fi
    done
  else
    echo "  PATCH_SET bos (patch'siz stock vLLM)"
  fi

  echo "--- model ---"
  if [ "$DOWNLOAD_MODEL" = "1" ]; then
    if [ -f "$MODEL_DIR/config.json" ]; then
      echo "  [ok] $MODEL_DIR"
      if [ -f "$MODEL_DIR/mtp.safetensors" ]; then
        echo "  [ok] mtp.safetensors (MTP speculative decode kullanilabilir)"
      elif [ "$ENABLE_MTP" = "1" ]; then
        echo "  [UYARI] mtp.safetensors yok ama ENABLE_MTP=1"
        _rc=1
      fi
    else
      echo "  [EKSIK] $MODEL_DIR  ->  sh $0 --env $ENV_FILE install"
      _rc=1
    fi
  else
    echo "  MODEL_ID=$MODEL_ID (HF cache uzerinden)"
  fi

  echo "--- GPU ---"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=index,name,memory.total,memory.used,ecc.mode.current \
      --format=csv,noheader -i "${CUDA_VISIBLE_DEVICES%%,*}" 2>/dev/null | sed 's/^/  /'
    echo "  NOT: L40S'te ECC acik oldugu icin toplam ~46068 MiB (~45.0 GiB) gorunur, 49152 degil."
  else
    echo "  nvidia-smi yok"
    _rc=1
  fi

  echo "--- profil ---"
  echo "  MODE=$MODE  vision=$ENABLE_VISION  max_model_len=$MAX_MODEL_LEN  max_num_seqs=$MAX_NUM_SEQS"
  echo "  gpu_util=$GPU_UTIL  kv=$KV_CACHE_DTYPE  ssm_state=$MAMBA_SSM_CACHE_DTYPE  mtp=$ENABLE_MTP (k=$SPEC_TOKENS)"

  echo "--- canli sunucu ---"
  if curl -sf -m 3 -H "Authorization: Bearer $API_KEY" "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
    echo "  [ok] http://127.0.0.1:$PORT ayakta"
    if [ -f "$LOG_FILE" ]; then
      grep -Ei 'GPU KV cache size|Maximum concurrency|Using .* backend|Available KV cache memory' "$LOG_FILE" \
        | tail -n 6 | sed 's/^/  /'
    fi
  else
    echo "  sunucu ayakta degil (veya API key gerekli)"
  fi

  echo ""
  if [ "$_rc" = "0" ]; then
    echo "verify: OK"
  else
    echo "verify: eksikler var (yukari bak)"
  fi
  return "$_rc"
}

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------
start() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "vLLM zaten calisiyor (PID $(cat "$PID_FILE"))"
    exit 0
  fi

  if [ ! -x "$VLLM_BIN" ]; then
    echo "HATA: $VLLM_BIN yok. Once: sh $0 --env $ENV_FILE install"
    exit 1
  fi

  _model="$(resolve_model_path)"
  if [ "$DOWNLOAD_MODEL" = "1" ] && [ ! -f "$MODEL_DIR/config.json" ]; then
    echo "HATA: model yok: $MODEL_DIR (once install, veya DOWNLOAD_MODEL=0)"
    exit 1
  fi

  if [ "$ENABLE_MTP" = "1" ] && [ -n "$PATCH_SET" ] && [ ! -f "$PATCH_MARKER" ]; then
    echo "UYARI: ENABLE_MTP=1 ama patch marker yok ($PATCH_MARKER)."
    echo "       Eszamanli MTP isteklerinde illegal-memory-access riski var."
    echo "       Onerilen: sh $0 --env $ENV_FILE patch"
  fi

  build_help_cache
  wait_for_free_gpu

  export CUDA_VISIBLE_DEVICES
  # GOTCHA: opsiyonel DEGIL. DeltaNet prefill kernel'leri gecici workspace
  # ayirir; bu olmadan allocator parcalanir ve gpu_util ~0.975 ustunde
  # calisma aninda OOM olur.
  export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
  if [ -n "$FLASHINFER_SAMPLER" ]; then
    export VLLM_USE_FLASHINFER_SAMPLER="$FLASHINFER_SAMPLER"
  fi
  if [ -n "$API_KEY" ]; then
    export VLLM_API_KEY="$API_KEY"
  fi

  set --

  set -- "$@" --served-model-name "$SERVED_MODEL_NAME"
  set -- "$@" --host "$HOST" --port "$PORT"
  set -- "$@" --gpu-memory-utilization "$GPU_UTIL"
  set -- "$@" --max-model-len "$MAX_MODEL_LEN"
  set -- "$@" --max-num-seqs "$MAX_NUM_SEQS"
  # GOTCHA: buyuk prefill chunk'lari (8192) profillenen activation peak'i
  # buyutur, bu da KV pool'u kucultur, bu da eszamanliligi kisar. 2048 kazanir.
  set -- "$@" --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS"
  set -- "$@" --kv-cache-dtype "$KV_CACHE_DTYPE"

  if [ -n "$MAMBA_SSM_CACHE_DTYPE" ] && check_flag_supported "--mamba-ssm-cache-dtype"; then
    # 64 layer'in 48'i Gated DeltaNet; recurrent state fp32'de ~150 MB/istek ve
    # her decode adiminda okunup yaziliyor. Bu mimaride eszamanliligi sinirlayan
    # sey KV cache degil bu state. float16 hem ayak izini hem trafigi yariya
    # indirir; perplexity uc ondaliga kadar ayni kalir.
    set -- "$@" --mamba-ssm-cache-dtype "$MAMBA_SSM_CACHE_DTYPE"
  else
    echo "UYARI: bu vLLM --mamba-ssm-cache-dtype desteklemiyor; atlandi."
    echo "       Recurrent state fp32 kalir -> eszamanlilik ve decode hizi duser."
  fi

  if [ "$ENABLE_VISION" = "0" ]; then
    if check_flag_supported "--language-model-only"; then
      set -- "$@" --language-model-only
    else
      echo "UYARI: --language-model-only desteklenmiyor; vision tower yuklenecek."
    fi
  fi

  if [ "$ASYNC_SCHEDULING" = "1" ] && check_flag_supported "--async-scheduling"; then
    set -- "$@" --async-scheduling
  fi

  if check_flag_supported "--api-server-count"; then
    set -- "$@" --api-server-count "$API_SERVER_COUNT"
  fi

  if [ -n "$ATTENTION_BACKEND" ]; then
    if check_flag_supported "--attention-backend"; then
      set -- "$@" --attention-backend "$ATTENTION_BACKEND"
    else
      echo "UYARI: --attention-backend desteklenmiyor; ATTENTION_BACKEND=$ATTENTION_BACKEND atlandi."
    fi
  fi

  if [ "$ENABLE_MTP" = "1" ]; then
    # FP8 checkpoint mtp.safetensors ile geliyor, ayri draft model gerekmiyor.
    # k=3: FlashInfer/fp8 KV yolunda k=4, bir istek biterken digeri uretimin
    # ortasindaysa engine'i illegal memory access ile dusuruyor.
    set -- "$@" --speculative-config \
      "{\"method\":\"mtp\",\"num_speculative_tokens\":$SPEC_TOKENS,\"draft_sample_method\":\"$DRAFT_SAMPLE_METHOD\"}"
  fi

  if [ "$ENFORCE_EAGER" = "1" ]; then
    set -- "$@" --enforce-eager
  else
    if [ -n "$CUSTOM_OPS" ]; then
      _ops="$(echo "$CUSTOM_OPS" | sed 's/[^,]*/"&"/g')"
    else
      _ops=""
    fi
    set -- "$@" --compilation-config \
      "{\"max_cudagraph_capture_size\":$CUDAGRAPH_CAPTURE_SIZE,\"custom_ops\":[$_ops]}"
  fi

  if [ -n "$REASONING_PARSER" ]; then
    # Thinking metnini reasoning_content alanina ayirir (llama.cpp'deki
    # --reasoning-format deepseek karsiligi).
    set -- "$@" --reasoning-parser "$REASONING_PARSER"
  fi

  if [ "$ENABLE_TOOLS" = "1" ]; then
    set -- "$@" --enable-auto-tool-choice --tool-call-parser "$TOOL_CALL_PARSER"
  fi

  if [ -n "$CHAT_TEMPLATE_FILE" ]; then
    if [ ! -f "$CHAT_TEMPLATE_FILE" ]; then
      echo "HATA: chat template dosyasi yok: $CHAT_TEMPLATE_FILE"
      exit 1
    fi
    set -- "$@" --chat-template "$CHAT_TEMPLATE_FILE"
  fi

  if [ -n "$OVERRIDE_GENERATION_CONFIG" ]; then
    if check_flag_supported "--override-generation-config"; then
      set -- "$@" --override-generation-config "$OVERRIDE_GENERATION_CONFIG"
    else
      echo "UYARI: --override-generation-config desteklenmiyor; atlandi."
    fi
  fi

  case "$PREFIX_CACHING" in
    1) set -- "$@" --enable-prefix-caching ;;
    0) if check_flag_supported "--no-enable-prefix-caching"; then
         set -- "$@" --no-enable-prefix-caching
       else
         echo "UYARI: --no-enable-prefix-caching desteklenmiyor; atlandi."
       fi ;;
  esac

  if [ -n "$SWAP_SPACE" ]; then
    set -- "$@" --swap-space "$SWAP_SPACE"
  fi

  : > "$LOG_FILE"

  echo ""
  echo "vLLM baslatiliyor..."
  echo "Model:   $_model"
  echo "Profil:  MODE=$MODE (vision=$ENABLE_VISION, ctx=$MAX_MODEL_LEN, slots=$MAX_NUM_SEQS)"
  echo "KV:      $KV_CACHE_DTYPE    SSM state: $MAMBA_SSM_CACHE_DTYPE    gpu_util: $GPU_UTIL"
  if [ "$ENABLE_MTP" = "1" ]; then
    echo "Spec:    MTP k=$SPEC_TOKENS ($DRAFT_SAMPLE_METHOD)"
  else
    echo "Spec:    kapali"
  fi
  echo "Log:     $LOG_FILE"
  echo ""

  # shellcheck disable=SC2086
  nohup "$VLLM_BIN" serve "$_model" "$@" $EXTRA_ARGS > "$LOG_FILE" 2>&1 &
  SERVER_PID=$!
  echo "$SERVER_PID" > "$PID_FILE"

  echo "Baslatildi (PID: $SERVER_PID)"
  echo "Ilk start dakikalar surer (torch.compile + CUDA graph capture + flashinfer JIT)."
  if [ -n "$API_KEY" ]; then
    echo "API key korumasi: aktif"
  else
    echo "API key korumasi: KAPALI  (HOST=$HOST ise mutlaka firewall/reverse-proxy kullan)"
  fi
  echo ""
  echo "Takip:  sh $0 --env $ENV_FILE log"
  echo "Test:   sh $0 --env $ENV_FILE test"
}

# ---------------------------------------------------------------------------
# stop / log / clearlog / status / test
# ---------------------------------------------------------------------------
stop() {
  if [ ! -f "$PID_FILE" ]; then
    echo "Calismiyor (PID dosyasi yok)"
    exit 0
  fi

  PID="$(cat "$PID_FILE")"
  if kill -0 "$PID" 2>/dev/null; then
    echo "vLLM durduruluyor (PID $PID)..."
    kill "$PID"
    for _ in $(seq 1 60); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$PID" 2>/dev/null; then
      echo "Zorla durduruluyor..."
      kill -9 "$PID" 2>/dev/null || true
      sleep 2
    fi
    echo "Durduruldu"
  else
    echo "Surec $PID canli degil; temizleniyor"
  fi
  rm -f "$PID_FILE"

  # Bir sonraki start'in kirli GPU uzerine dusmemesi icin VRAM'in gercekten
  # geri verilmesini bekle.
  if [ "$GPU_FREE_WAIT" = "1" ] && command -v nvidia-smi >/dev/null 2>&1; then
    _i=0
    while [ "$_i" -lt 60 ]; do
      _u="$(gpu_used_mib)"
      case "$_u" in ''|*[!0-9]*) break ;; esac
      [ "$_u" -le "$GPU_FREE_MIB" ] && break
      sleep 1
      _i=$((_i + 1))
    done
    echo "GPU kullanimi: $(gpu_used_mib) MiB"
  fi
}

log() {
  if [ ! -f "$LOG_FILE" ]; then
    echo "Log dosyasi yok: $LOG_FILE"
    exit 1
  fi
  tail -n 255 -f "$LOG_FILE"
}

clearlog() {
  if [ ! -f "$LOG_FILE" ]; then
    echo "Log dosyasi yok: $LOG_FILE"
    exit 0
  fi
  : > "$LOG_FILE"
  echo "Log temizlendi: $LOG_FILE"
}

status() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "vLLM calisiyor (PID $(cat "$PID_FILE"))"
  else
    echo "vLLM calismiyor"
  fi
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu \
      --format=csv -i "${CUDA_VISIBLE_DEVICES%%,*}"
  fi
  if [ -f "$LOG_FILE" ]; then
    grep -Ei 'GPU KV cache size|Maximum concurrency|Using .* backend' "$LOG_FILE" | tail -n 4 || true
  fi
  true
}

test_request() {
  _ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "$_ip" ] || _ip=127.0.0.1

  echo "POST http://127.0.0.1:$PORT/v1/chat/completions"
  set -- -sS "http://127.0.0.1:$PORT/v1/chat/completions" -H "Content-Type: application/json"
  if [ -n "$API_KEY" ]; then
    set -- "$@" -H "Authorization: Bearer $API_KEY"
  fi
  curl "$@" -d "{\"model\":\"$SERVED_MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Merhaba dunya! Tek cumleyle kendini tanit.\"}],\"max_tokens\":256,\"chat_template_kwargs\":{\"enable_thinking\":false}}"
  echo ""
  echo ""
  echo "Disaridan: http://$_ip:$PORT/v1   (model adi: $SERVED_MODEL_NAME)"
}

case "$CMD" in
  install)  install ;;
  patch)    patch_vllm ;;
  verify)   verify ;;
  start)    start ;;
  stop)     stop ;;
  log)      log ;;
  clearlog) clearlog ;;
  status)   status ;;
  test)     test_request ;;
  *)
    echo "Usage: $0 {install|patch|verify|start|stop|log|clearlog|status|test} [--env /path/to/.env]"
    exit 1 ;;
esac
