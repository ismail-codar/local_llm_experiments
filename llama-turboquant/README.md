# llama-turboquant — Yerel LLM Yığını

NVIDIA L40S 48GB üzerinde **TurboQuant KV cache + MTP + multimodal + llama-ui + çoklu model routing** için yapılandırılmış başlatıcı betikleri.

İki ayrı llama.cpp build'i kullanır:

| Build | Klasör | Kullandığı modeller |
|---|---|---|
| **TheTom/llama-cpp-turboquant** (fork) | `llama-cpp-turboquant/` | Qwen3.6 ailesi — `turbo3/4` KV cache + MTP draft |
| **ggml-org/llama.cpp** (upstream) | `llama.cpp/` | SuperGemma4 — sadece standart kuantizasyon |

Modeller `../models/` altında (parent klasörle paylaşılan), loglar her script kendi `.log` dosyasını yazar.

---

## Dosya rehberi

### Kurulum

| Dosya | Ne yapar |
|---|---|
| `install.sh` | **TheTom/llama-cpp-turboquant** fork'unu (`feature/turboquant-kv-cache` branch) klonlar, CUDA 13.0 + OpenSSL + arch=89 (L40S) ile derler. Çıktı: `llama-cpp-turboquant/build/bin/llama-server` |
| `install-gemma4.sh` | Vanilla **ggml-org/llama.cpp** klonlar ve aynı CUDA ayarlarıyla derler. Çıktı: `llama.cpp/build/bin/llama-server` |
| `install-swap.sh` | `mostlygeek/llama-swap` binary'sini (varsayılan `v217`) `bin/llama-swap` altına indirir. Mimari otomatik (`x86_64` → `amd64`, `aarch64` → `arm64`) |

### Çalıştırıcılar (tek model modu)

| Dosya | Model | Build | Özellikler |
|---|---|---|---|
| `run.sh` | Qwen3.6-35B-A3B Q5_K_XL (MTP) | turboquant fork | turbo4 KV, 256K ctx, MTP draft, llama-ui, **opsiyonel multimodal** (`ENABLE_MMPROJ=1`), `--no-webui`/`--api-key`/`--slots` |
| `run-gemma4.sh` | supergemma4-26b-abliterated-multimodal Q4_K_M + mmproj-f16 | vanilla llama.cpp | 256K ctx, multimodal, np=4 |

### Çoklu model + routing modu

| Dosya | Ne yapar |
|---|---|
| `swap.yaml` | llama-swap örnek config — TheTom fork üzerinden `qwen3.6-35b-mtp` profili (text + vision), TTL, alias'lar |
| `run-swap.sh` | llama-swap'i tek port (`8001`) arkasında başlatır. OpenAI API'deki `model` alanına göre llama-server'ı spawn/swap eder |

### Yardımcı

| Dosya | Ne yapar |
|---|---|
| `stop.sh` | Önce llama-swap, sonra tüm llama-server süreçlerini SIGTERM → SIGKILL ile kapatır |
| `ngrok_proxy.sh` | `8001` portunu ngrok ile dışarı açar (`run.sh` ve `run-swap.sh` de aynı portu kullanır). Public URL: `curl -s http://127.0.0.1:4040/api/tunnels` |

---

## Mimari özet

```
TEK MODEL MODU (run.sh / run-gemma4.sh)
┌─────────────────────────────────────────────┐
│  llama-server  (port 8001)                  │
│  • OpenAI API  /v1/*                        │
│  • llama-ui    /                            │
│  • TurboQuant KV + MTP + opsiyonel mmproj   │
└─────────────────────────────────────────────┘

ÇOKLU MODEL MODU (run-swap.sh)
        ┌─────────────────────────────────────────────┐
        │  llama-swap   (port 8001, tek giriş)        │
        │  • OpenAI API  /v1/*                        │
        │  • llama-ui    /  (aktif modelinki)         │
        │  • Routing: model="qwen3.6-35b-mtp" → spawn │
        └─────────────────────┬───────────────────────┘
                              │
                              ▼
                       llama-server
                       Qwen3.6 35B
                       MTP + mmproj + turbo4
                       (dahili port 10001+)
```

> **Not:** Tek model modu (`run.sh`) ile çoklu model modu (`run-swap.sh`) **aynı portu (8001) kullanır** — ikisi aynı anda çalıştırılamaz. Birinden diğerine geçerken `./stop.sh`.

Tek L40S 48GB: aynı anda **tek model** VRAM'de. Swap geçişi cold start (~10-30 sn). `globalTTL: 1800` ile 30 dk boştaki model otomatik unload.

---

## İlk kurulum (sırayla)

```sh
cd llama-turboquant

# 1) TurboQuant fork'unu derle (Qwen3.6 modelleri için)
./install.sh

# 2) Vanilla llama.cpp'yi derle (Gemma4 için — opsiyonel)
./install-gemma4.sh

# 3) llama-swap binary'sini indir (çoklu model modu için — opsiyonel)
./install-swap.sh
```

Sistem gereksinimleri:
- Ubuntu/Debian
- CUDA 13.0 + nvcc PATH'te
- `aria2c` (model indirme için): `sudo apt-get install -y aria2`
- `curl` veya `wget` (swap binary için)

---

## Kullanım senaryoları

### A) Tek model — Qwen3.6 35B MTP (text-only veya text+vision)

```sh
# Sadece text (varsayilan, en hizli)
./run.sh

# Text + vision (multimodal — mmproj otomatik indirilir)
# Dosyanin basindaki ENABLE_MMPROJ=0'i 1 yap, sonra:
./run.sh

# → http://<host>:8001  (llama-ui)
# → http://<host>:8001/v1/chat/completions
```

`run.sh` içindeki değişkenler:
- `ENABLE_MMPROJ=1|0` — multimodal (vision) açık/kapalı; açıkken `--mmproj` ekler ve mmproj-F16.gguf'u indirir
- `ENABLE_WEBUI=1|0` — UI kapat (`--no-webui`)
- `API_KEY="..."` — Authorization: Bearer ile koru
- `ENABLE_SLOTS=1|0` — `/slots` endpoint
- `REASONING_BUDGET` — 0 (kapalı) / 4096 (dengeli) / 8192 (uzun düşünme)
- `CACHE_TYPE_K`, `CACHE_TYPE_V` — `turbo3` (~3.5bit) veya `turbo4` (~4.5bit)
- `SPEC_DRAFT_N_MAX` — MTP taslak token sayısı (6 önerilen)

### B) Tek model — SuperGemma4 multimodal

```sh
./run-gemma4.sh
# → http://<host>:8001
```

### C) Çoklu model + routing (önerilen üretim akışı)

Modelleri **`../models/`** altına indir. En kolay yol: `run.sh`'i bir kez `ENABLE_MMPROJ=1` ile çalıştır (gguf + mmproj iner), sonra `./stop.sh` ile durdur ve swap moduna geç.

`swap.yaml` (örnek, tek profil) içindeki dosya isimleri:
```
../models/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf
../models/mmproj-F16.gguf
```

Başlat:
```sh
./run-swap.sh
# → http://<host>:8001  (tek giriş)
```

Test:
```sh
# Modelleri listele
curl -s http://localhost:8001/v1/models | jq

# Chat (alias kullanımı)
curl -s http://localhost:8001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6",
    "messages": [{"role":"user","content":"Merhaba"}]
  }'

# Multimodal: image_url ile
curl -s http://localhost:8001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6-35b-mtp",
    "messages": [{
      "role":"user",
      "content":[
        {"type":"text","text":"Bu görselde ne var?"},
        {"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}
      ]
    }]
  }'
```

WebUI (llama-ui) `http://localhost:8001/` adresinde — şu anda yüklü modelinki sunulur.

Yeni model profili eklemek için bkz. aşağıdaki **Yapılandırma referansı** bölümü.

### D) Dış erişim (ngrok)

```sh
./run.sh           # veya run-swap.sh — her ikisi de 8001'de
./ngrok_proxy.sh
curl -s http://127.0.0.1:4040/api/tunnels | jq -r '.tunnels[0].public_url'
```

---

## Durdurma

```sh
./stop.sh
```

Tüm `llama-swap` + `llama-server` süreçlerini SIGTERM → 2sn → SIGKILL ile kapatır. Swap modunda swap kendi spawn ettiği server'ları da temizler.

---

## Yapılandırma referansı

### `swap.yaml` profilleri ne içerir

Her profil bir `cmd:` bloğunda llama-server komutunu açar. Ortak parçalar `macros:` altında:

- `turbo_dir` → TheTom fork'unun build path'i (`~/local_claude/llama-turboquant/llama-cpp-turboquant`)
- `models_dir` → `~/local_claude/models`

`startPort: 10001` — swap, llama-server'ları 10001'den itibaren dahili portlara bağlar.
`${PORT}` — swap tarafından otomatik atanan port.
`globalTTL: 1800` — boştaki modeli 30 dk sonra unload.
`healthCheckTimeout: 600` — 256K ctx + MTP cold start uzun sürebilir; bekleme süresi.

### Model aliası ekleme

```yaml
"qwen3.6-35b-mtp":
  aliases:
    - "qwen3.6"
    - "qwen"
```

`model: "qwen"`, `model: "qwen3.6"` ve `model: "qwen3.6-35b-mtp"` aynı profile düşer.

### API anahtarı (swap düzeyinde)

`swap.yaml`'a ekle:
```yaml
apiKeys:
  - "sk-yourkey"
  - "${env.API_KEY}"   # run-swap.sh'tan export edilir
```

Sonra:
```sh
API_KEY=sk-yourkey ./run-swap.sh
curl -H "Authorization: Bearer sk-yourkey" http://localhost:8001/v1/models
```

### Yeni model profili eklemek

`swap.yaml` → `models:` altına yeni bir blok:

```yaml
"yeni-model":
  name: "Açıklayıcı isim"
  cmd: |
    ${turbo_dir}/build/bin/llama-server
    --host 127.0.0.1 --port ${PORT}
    -m ${models_dir}/dosya.gguf
    -c 32768
    -ngl 99
    -np 1
    --flash-attn on
    --cont-batching
    --jinja
    --cache-type-k turbo4
    --cache-type-v turbo4
  ttl: 600
```

Reload: `./stop.sh && ./run-swap.sh`.

---

## TurboQuant cache tipleri

| Tip | Bit/eleman | Sıkıştırma | PPL kaybı | Notlar |
|---|---|---|---|---|
| `turbo2` | ~2.0 | ~7× | yüksek | Sadece V için; agresif |
| `turbo3` | ~3.5 | ~4.6× | <1.5% | Dengeli |
| `turbo4` | ~4.5 | ~3.5× | düşük | Varsayılan, kalite önceliği |

Asimetrik kullanım örneği (`run.sh` veya `swap.yaml`):
```
--cache-type-k turbo4 --cache-type-v turbo3
```
K daha hassas → turbo4; V daha toleranslı → turbo3 (daha az VRAM).

---

## Speculative decoding

Speculative decoding: hızlı bir "draft" üreteciyle birkaç token tahmin et, ana modelle paralelde **doğrula**; doğrulananları kabul et, sapmadan sonrasını at. Kalite **birebir aynı** (sampling deterministik aynı), hız 1.5–3×.

llama.cpp'de iki mod var:

| Mod | Draft kaynağı | Bayraklar | Ne zaman |
|---|---|---|---|
| **MTP** (built-in) | Model dosyasının içindeki MTP head'leri | `--spec-type draft-mtp` (yeni) / `mtp` (eski) + `--spec-draft-n-max N` | Model `*-MTP-GGUF` ise. Tek model, ekstra VRAM ~minimum |
| **Klasik draft** | Ayrı, küçük "draft" GGUF (örn. 0.5B–1B aynı tokenizer) | `-md <path>` / `--model-draft` + `--draft-max N` + `-ngld N` | Modelin MTP varyantı yoksa. ~+1-3 GB VRAM |

### A) MTP modu — Qwen3.6 35B / 27B MTP modelleri (önerilen)

Modelin kendi içinde MTP başlıkları var → ayrı draft model gerekmez. `run.sh` zaten bu modda çalışıyor.

**`run.sh` üzerinden:**
```sh
# run.sh icinde zaten ayarli:
SPEC_DRAFT_N_MAX=6      # her adimda en fazla 6 taslak token
# SPEC_TYPE otomatik secilir: 'draft-mtp' (yeni) veya 'mtp' (eski)

./run.sh
# Log'da goreceksin:
# Secilen spec-type: draft-mtp
# slot ... drafted=5 accepted=4
```

llama.cpp 13 Mayıs 2026 civarında bayrak adını değiştirdi:
- Eski (eski TheTom fork'ları): `--spec-type mtp`
- Yeni: `--spec-type draft-mtp`

`run.sh` build'in `--help` çıktısından otomatik seçer. `swap.yaml` mevcut güncel fork için `draft-mtp` kullanır — fork eski sürümdeyse `swap.yaml`'da `draft-mtp` → `mtp` olarak değiştir.

**`swap.yaml` üzerinden:**
```yaml
"qwen3.6-35b-mtp":
  cmd: |
    ${turbo_dir}/build/bin/llama-server
    --host 127.0.0.1 --port ${PORT}
    -m ${models_dir}/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf
    -c 262144 -ngl 99 -np 1
    --spec-type draft-mtp
    --spec-draft-n-max 6
```

**Tuning:**
- `--spec-draft-n-max 6` — varsayılan ve önerilen. Qwen MoE'de 12'ye çıkarmak fayda sağlamaz (kabul oranı düşer).
- Reasoning içerikte kabul oranı yüksek (~%70-80), serbest yaratıcı yazıda düşer (~%40-50).
- Beklenen hız: **1.5–2.0× t/s** Qwen3.6-35B'de.

### B) Klasik draft model modu — herhangi bir GGUF için

Hedef modelin MTP varyantı yoksa veya farklı bir mimari kullanıyorsan, ayrı küçük bir "draft" modelle hız kazandırabilirsin. **Şart:** draft model **aynı tokenizer'i** kullanmalı (aynı aileden, çok daha küçük).

Örnek eşleşmeler:
| Hedef model | İyi bir draft adayı |
|---|---|
| Qwen3.6-35B | Qwen3.6-1.7B / 0.5B (aynı aile) |
| Llama-3.1-70B | Llama-3.2-1B veya 3B |
| Gemma3-27B | Gemma3-1B |

**Doğrudan `llama-server` ile (run.sh'a benzer şekilde):**
```sh
./build/bin/llama-server \
  -m ../models/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf \
  -md ../models/Qwen3.6-1.7B-Q4_K_M.gguf \
  -ngl 99 \
  -ngld 99 \
  -c 262144 \
  -cd 8192 \
  --draft-max 8 \
  --draft-min 2 \
  --draft-p-min 0.6 \
  --host 0.0.0.0 --port 8001 \
  --jinja --flash-attn on --cont-batching
```

Önemli bayraklar:
- `-md, --model-draft <path>` — draft GGUF
- `-ngld, --gpu-layers-draft N` — draft modelin GPU'ya alınacak katman sayısı (genelde 99)
- `-cd, --ctx-size-draft N` — draft için ayrı (küçük) context, RAM tasarrufu
- `--draft-max N` — her turda en fazla N taslak token (default 16; 4-8 daha tutarlı)
- `--draft-min N` — minimum kabul edilebilir taslak uzunluğu
- `--draft-p-min P` — sadece olasılığı P'den yüksek tokenları teklif et (0.6-0.8 dengeli)
- `--draft-device <dev>` — opsiyonel: draft için ayrı GPU/CPU (örn. ana model GPU 0, draft CPU)

**`swap.yaml` üzerinden:**
```yaml
"qwen3.6-35b-draft":
  name: "Qwen3.6 35B + 1.7B draft (klasik spec decoding)"
  cmd: |
    ${turbo_dir}/build/bin/llama-server
    --host 127.0.0.1 --port ${PORT}
    -m ${models_dir}/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf
    -md ${models_dir}/Qwen3.6-1.7B-Q4_K_M.gguf
    -ngl 99 -ngld 99
    -c 262144 -cd 8192
    --draft-max 8 --draft-min 2 --draft-p-min 0.6
    --flash-attn on --cont-batching --jinja -t 0
    --cache-type-k turbo4 --cache-type-v turbo4
  ttl: 1800
```

`run.sh`'a klasik draft modunu eklemek istersen (MTP yerine), `--spec-type` ve `--spec-draft-n-max` satırlarını çıkar, yerine `-md ... -ngld 99 --draft-max 8 ...` ekle.

### Hangi modu seçmeliyim?

| Durum | Seçim |
|---|---|
| Modelin `*-MTP-GGUF` varyantı var | **MTP** — daha az VRAM, tek dosya, kalibre |
| MTP varyantı yok ama aynı aileden küçük model var | **Klasik draft** |
| Çok agresif hız + biraz kalite kaybı OK | Klasik + `--draft-max 12 --draft-p-min 0.4` |
| Garanti kalite, minimal kazanç yeter | MTP `n_max=4` veya klasik `--draft-max 4 --draft-p-min 0.8` |

### Doğrulama: çalışıyor mu?

`tail -f llama-server.log` — şu satırları arıyoruz:
```
slot ... drafted=N accepted=M    # her istek için
print_timings: speculative ...    # özet
```

`accepted / drafted` oranı %50 üstündeyse net kazanç var. %30'un altındaysa parametreleri sıkılaştır (`--draft-p-min` artır veya `--draft-max` azalt).

---

## Sorun giderme

| Belirti | Bakılacak yer |
|---|---|
| `llama-server bulunamadi` | İlgili `install*.sh` çalıştı mı? `ls llama-cpp-turboquant/build/bin/` |
| `MTP spec decoding desteklemiyor` | Fork eski sürümde, `git -C llama-cpp-turboquant pull` + rebuild |
| `mmproj-F16.gguf yok` | Unsloth Qwen3.6-…-MTP-GGUF repo'sundan ayrıca indir |
| Swap'te model timeout | `healthCheckTimeout: 600`'ü artır; `tail -f llama-swap.log` |
| WebUI boş geliyor | İlk istek model yükleme bekliyor; log'da `loading model` görmelisin |
| VRAM dolu | `nvidia-smi`; başka llama-server var mı? `pkill -f llama-server` |
| Port çakışması | `lsof -i:8000` / `lsof -i:8001`; `PORT=8002 ./run-swap.sh` |

Log konumları:
- `llama-server.log` — tek model modu (run.sh / run-gemma4.sh)
- `llama-swap.log` — swap modu (run-swap.sh)
- llama-swap proxy log: stdout'a (`logToStdout: "proxy"`) — aynı `llama-swap.log`'a düşer

---

## Performans notları (L40S 48GB)

- Qwen3.6-35B-A3B Q5_K_XL: ~27 GB weights + ~15-18 GB KV (256K ctx, turbo4) ≈ 42-45 GB. Sıkışık ama çalışır.
- Daha fazla baş alan istiyorsan: `CTX_SIZE=131072` (128K) veya `CACHE_TYPE_V=turbo3`.
- Q6_K_XL'a çıkmak istersen: ctx'i 128K'ya düşür.
- MTP `n_max=6` Qwen3.6'da tipik **1.5–2.0× hız**; reasoning içerikte daha iyi.
- Multimodal varken `np` (parallel slots) düşük tut; vision encoder ek VRAM yer.

---

## Referanslar

- TheTom fork: <https://github.com/TheTom/llama-cpp-turboquant>
- llama-ui PR/discussion: <https://github.com/ggml-org/llama.cpp/discussions/16938>
- llama-swap: <https://github.com/mostlygeek/llama-swap>
- llama-swap config schema: <https://raw.githubusercontent.com/mostlygeek/llama-swap/refs/heads/main/config-schema.json>
- Qwen3.6 MTP GGUF (text+mmproj): <https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF>
- Qwen3.6 27B MTP GGUF: <https://huggingface.co/unsloth/Qwen3.6-27B-MTP-GGUF>
- SuperGemma4 GGUF: <https://huggingface.co/Jiunsong/supergemma4-26b-abliterated-multimodal-gguf-4bit>
