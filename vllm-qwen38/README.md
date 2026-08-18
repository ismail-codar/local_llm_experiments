# Qwen3.8-27B on vLLM — NVIDIA L40S 48 GB

[syv-ai/qwen38-27b-rtx3090](https://github.com/syv-ai/qwen38-27b-rtx3090) kurulumunun
**L40S 48 GB uyarlamasi**. Temiz baslangic: `llama-turboquant/` (llama.cpp + TurboQuant)
ile hicbir sey paylasmiyor, yaninda bagimsiz durur.

- `cli.sh` — env tabanli kontrol scripti (`llama-turboquant/cli.sh` ile ayni sozlesme)
- `qwen3.8-27b-l40s.env` — tek profil dosyasi, `MODE` ile uc calisma bicimi

```
sh ./cli.sh --env ./qwen3.8-27b-l40s.env install   # venv + vLLM 0.27.1 + model (~31 GB)
sh ./cli.sh --env ./qwen3.8-27b-l40s.env patch     # gerekli vLLM patch'i
sh ./cli.sh --env ./qwen3.8-27b-l40s.env verify    # kurulum/patch/GPU/profil kontrolu
sh ./cli.sh --env ./qwen3.8-27b-l40s.env start
sh ./cli.sh --env ./qwen3.8-27b-l40s.env log
sh ./cli.sh --env ./qwen3.8-27b-l40s.env test      # ornek /v1/chat/completions
sh ./cli.sh --env ./qwen3.8-27b-l40s.env stop
```

Gereksinimler: Linux + NVIDIA driver, CUDA 12.8+, Python 3.12, ~35 GB disk, `patch`, `git`.
Port **8010** (`llama-turboquant` 8001-8009 ve `vllm/cli*.sh` 8000 ile cakismaz).

## MODE profilleri

| | `single` (varsayilan) | `longctx` | `batch` |
|---|---|---|---|
| icin | 1-4 aktif oturum, gunluk kullanim | tam native context | API backend, cok eszamanli istek |
| vision | **acik** | kapali | kapali |
| `max-model-len` | 131072 | **262144** | 131072 |
| `max-num-seqs` | 4 | 2 | 64 |
| `gpu-memory-utilization` | 0.93 | 0.93 | 0.95 |
| KV | fp8 | fp8 | fp8 |
| MTP spec decode | k=3 | k=3 | kapali |
| CUDA graph capture | 32 | 32 | 64 |

Preset degerleri **sadece env'de ayarlanmamis** degiskenleri doldurur; env'de acikca
yazdigin deger her zaman kazanir. Kabaca 8 eszamanli kullanicinin ustunde duz
continuous batching speculative decoding'i yener — orada `MODE=batch`.

## Neden FP8, W4A16 degil

3090 kurulumu W4A16 AutoRound (19.5 GB) kullanmak **zorundaydi**: 24 GB'a baska bir sey
sigmiyordu ve Ampere'de fp8 tensor core yok. L40S'te ikisi de gecerli degil.

| checkpoint | boyut | L40S'te |
|---|---|---|
| `Qwen/Qwen3.8-27B` (bf16) | 55.6 GB | sigmaz |
| **`Qwen/Qwen3.8-27B-FP8`** | **30.9 GB** | **secilen** — Ada (SM89) fp8 tensor core'lari native |
| `dbirks/Qwen3.8-27B-W4A16-AutoRound` | 19.5 GB | calisir; hizli ama kaliteden verir |
| `*-NVFP4` | ~12-25 GB | **kullanma** — Blackwell (SM100+) formati |

FP8'i seçme gerekcesi:

- Qwen'in resmi fp8'i block-128 fine-grained; kalite pratikte bf16 ile ayni. Upstream'in
  W4A16 stack'i IFBench prompt-level strict'te 79.5 → 78.3, yani ~1 puan veriyordu.
- `mtp.safetensors` (0.48 GB) checkpoint'in **icinde** geliyor → MTP speculative decoding
  icin ayri draft model yok.
- Vision tower da icinde (`outside.safetensors`) → llama.cpp'deki gibi ayri `mmproj` yok.
- 30.9 GB agirlik 48 GB'a sigar ve 262144 token fp8 KV icin yer birakir.

Mevcut `llama-turboquant/qwen3.8-27b.env` de kaliteyi hiz yerine seciyordu (UD-Q6_K_XL,
25.9 GB). FP8 o tercihin vLLM tarafindaki karsiligi — biraz daha yuksek bit, artik
continuous batching ve tool calling da var.

## VRAM butcesi

`nvidia-smi` L40S'te **~46068 MiB (~45.0 GiB)** gosterir, 49152 degil: ECC varsayilan
olarak acik. Butce buna gore.

**`single`** (vision acik, util 0.93, MTP k=3, 4 slot):

```
vLLM'in yonetebilecegi           41.9 GiB   (45.0 x 0.93)
  FP8 agirliklar (vision dahil)  28.8
  activation + graph + vision profil  4.0
  DeltaNet recurrent state (fp16)     1.2   (4 slot x (k+1) x 75 MB)
  MTP draft modulu                    0.5
  -------------------------------------
  KV icin kalan                       7.4
  131072 x 32 KB fp8 KV               4.0   ->  ~3.4 GiB marj
```

**`longctx`** (vision kapali, 2 slot): agirlik 27.9 + profil 2.5 + state 0.6 + drafter 0.5
= 31.5 GiB, kalan ~10.4 GiB; `262144 x 32 KB = 8.0 GiB` → **~2.4 GiB marj**.

KV maliyeti nereden: 64 layer'in tamami klasik KV uretmiyor — **16 full-attention + 48
Gated DeltaNet**. Full-attention tarafi 4 KV head x 256 head_dim, yani fp8'de
`16 x 4 x 256 x 2 (K+V) x 1 byte = 32 KB/token`. DeltaNet kismi token sayisiyla lineer
buyumez, slot basina sabittir.

Sonuç: **KVarN'a gerek yok.** Upstream 262144'e ancak 4-bit key / 2-bit value KV cache
(`kvarn/`) ile ulasabiliyordu ve karsiliginda uzun-context decode'da ~%20 veriyordu.
Bizde duz fp8 KV ile tam 262144 siger.

OOM olursa merdiven: `262144 → 196608 → 163840 → 131072`, ya da `MAX_NUM_SEQS` dusur,
ya da `ENABLE_VISION=0`.

## 3090 kurulumundan farklar

| upstream (3090 / 24 GB) | burada (L40S / 48 GB) | neden |
|---|---|---|
| W4A16 AutoRound + int8 requantize edilmis lm_head/embeddings | resmi FP8 checkpoint, requantize yok | 48 GB yetiyor, Ada'da fp8 native, ~1 IFBench puani geri |
| `--language-model-only` zorunlu (2.7 GB tasarruf) | `MODE=single`'da **vision acik** | VRAM var; mevcut llama.cpp env'i de vision'i acik tutuyordu |
| 150k max, 262144 icin KVarH/KVarN sart | duz fp8 KV ile **262144** (`MODE=longctx`) | agirliktan artan 10+ GiB KV'ye gidiyor |
| 7 patch (marlin int8, embed quant, draft vocab, sampler, spec-attn, GDN bounds) | **1 patch** (GDN bounds) varsayilan | marlin/embed patch'leri W4A16'ya ozel; digerleri opsiyonel |
| `gpu-memory-utilization` 0.972 (batch) / 0.93 (MTP) | 0.95 / 0.93 | 0.93'te bile 3.15 GiB mutlak marj var (3090'da 1.68) |
| `INT8_ACT=int8` W4A8 Marlin, +%2.2 perplexity | yok | fp8 W8A8 zaten native tensor core yolu; kalite kirmaya gerek yok |
| tek-akis 46 tok/s (spec'siz), ~114 (MTP + tuned drafter) | asagi bak | bandwidth 864 GB/s vs 936, agirlik 30 GB vs 17 |

Aynen tasinan seyler: `--mamba-ssm-cache-dtype float16`, `expandable_segments:True`,
`--max-num-batched-tokens 2048`, kirli-GPU kapisi, MTP'de 0.93 tavan, k=3 siniri.

## Beklenen performans

**Bu sayilar olculmedi — bandwidth aritmetiginden cikan tahminler.** Kendi kartinda
dogrulamadan karar verme.

Decode tek akista memory-bound: her token icin tum agirliklar okunuyor. L40S 864 GB/s
(3090'in 936'sindan **dusuk**; L40S'in avantaji bandwidth degil, compute ve VRAM).

| | agirlik okunan | teorik tavan | ~%85'te |
|---|---|---|---|
| FP8, spec decode yok | ~30 GB | 28 tok/s | ~24 tok/s |
| FP8 + MTP k=3 (~2.4 token/adim) | | | **~45-55 tok/s** |
| W4A16, spec decode yok | ~17 GB | 51 tok/s | ~43 tok/s |

Yani:

- **Tek-akis hizi tek onceligin ise FP8 dogru secim degil** — W4A16 (19.5 GB) ayni kartta
  kabaca 1.6x hizli olur, karsiliginda ~1 IFBench puani ve upstream'in requantize
  adimlarini calistirma zorunlulugu gelir.
- Mevcut llama.cpp Q6 kurulumun (25.9 GB) da ayni bandwidth duvarina carpiyor, yani
  FP8'e gecerken tek-akis tok/s'de buyuk bir atlama beklemeyin. Kazanc baska yerde:
  continuous batching, gercek tool calling, prefix caching, exact MTP, 262144.
- `MODE=batch` toplam throughput'ta 3090'in belirgin ustunde olmali (fp8 tensor core'lar
  ~5x compute), ama olcmeden sayi vermiyorum.

Olcmek icin upstream'in araclarini kullan — `sh ./cli.sh ... patch` sonrasi
`upstream-syv/` klonu elinde olur:

```bash
# throughput / latency
venv/bin/python -m vllm.entrypoints.cli.main bench serve \
  --base-url http://127.0.0.1:8010 --model qwen3.8-27b \
  --dataset-name custom --dataset-path upstream-syv/bench/prompts_real.jsonl

# kalite (perplexity + GSM8K) - degisiklik yaptiktan sonra ZORUNLU
venv/bin/python upstream-syv/bench/quality_battery.py fp8-l40s
```

## Gotcha'lar

Upstream'in acisini cektigi seyler; hepsi L40S'te de gecerli.

1. **Benchmark ciktinin sacma oldugunu soylemez.** Upstream'in int8-activation yolu bir
   saat boyunca guzel tok/s uretip anlamsiz metin dondurdu. Ne degistirirsen degistir,
   tok/s'e inanmadan once `quality_battery.py` calistir.
2. **Kirli GPU'ya baslamak sessizce %25 kaybettirir.** vLLM bos VRAM'i baslangicta bir kez
   olcer; onceki surec hala VRAM birakiyorsa cache pool ~%40 kucuk cikar, uyari yok,
   sunucu calisir, throughput kalici olarak kotu olur. `cli.sh start` GPU bosalana kadar
   bekler, `stop` da VRAM'in geri verilmesini bekler (`GPU_FREE_WAIT=0` ile atlanir).
3. **`PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` opsiyonel degil.** DeltaNet prefill
   kernel'leri gecici workspace ayirir; bu olmadan allocator parcalanir ve util ~0.975
   ustunde calisma aninda OOM olur. `cli.sh` bunu her zaman export eder.
4. **MTP acikken tavan 0.93.** Speculative decode yolunun DeltaNet workspace'i vLLM'in
   baslangic profillemesinin otesinde buyuyor. 0.95+ kisa benchmark'i gecip uzun
   uretimlerde istek ortasinda oluyor.
5. **`torch.compile` cache env var'larindan haberdar degil.** KV dtype, patch seti ya da
   custom_ops degistirdikten sonraki ilk start'i
   `VLLM_DISABLE_COMPILE_CACHE=1 sh ./cli.sh ... start` ile yap.
6. **Buyuk prefill chunk'lari zarar verir.** `--max-num-batched-tokens 8192` profillenen
   activation peak'i buyutur → KV pool kuculur → eszamanlilik kisilir. 2048 kazaniyor.
7. **MTP k=4 fp8 KV'de engine'i dusuruyor.** Bir istek biterken digeri uretimin
   ortasindaysa illegal memory access (vLLM 0.27.1, FlashInfer yolu). k=3 stabil. k=4
   istiyorsan bf16 KV'ye gecmen gerekir (env'de anlatiliyor) — o zaman 262144 gider.
8. **Rastgele-token benchmark'lari speculative decoding'i sisirir.** Ayni sunucu
   `--dataset-name random` ile 35, 83 ya da 151 tok/s okuyabiliyor. Gercek prompt kullan.
9. **Iki kez olc.** Restart sonrasi ilk kosu JIT warmup icerir ve %30-50 dusuk okur.
10. **Env dosyasi `source` ediliyor.** Bosluk/JSON iceren degerleri tek tirnakla:
    `EXTRA_ARGS='--tensor-parallel-size 1'`. Tirnaksiz yazmak ya "command not found" verir
    ya da JSON'u sessizce bozar.
11. **Vision acikken KV pool kuculur.** vLLM bellek profillemesini dummy max-cozunurluk
    goruntuyle yapar. `longctx`/`batch` bu yuzden vision'i kapatiyor.

## Patch'ler

`PATCH_SET` varsayilani: **`vllm-pr50021-gdn-spec-bounds`**.

DeltaNet/KDA speculative decode kernel'lerine bounds check ekliyor. Upstream vLLM
[PR #50021](https://github.com/vllm-project/vllm/pull/50021) **hala acik** (2026-08-18
itibariyla merge edilmedi) ve eszamanli MTP isteklerinde illegal-memory-access aliniyor.
MTP kullanacaksan bu patch pratikte gerekli. Quantization'dan bagimsiz, FP8'de guvenli;
vLLM 0.27.1 kaynagina karsi temiz uyguluyor (dogrulandi).

Opsiyonel eklenebilecekler — `PATCH_SET`'e bosluk ile ekle:

| patch | ne yapar | not |
|---|---|---|
| `speed-knobs-envs` + `sampler-small-topk-fast-softmax` | sort'suz top-k, multi-block softmax (248k vocab her satir icin sortlanmiyordu) | upstream'de ~+%4; 6 dosyaya dokunur, catisma riski yuksek |
| `spec-decode-attn` | multi-query verify adimi icin split-KV Triton attention | **sadece bf16 KV**; L40S'in 142 SM'i varken FA2'nin KV'yi bolmemesi 3090'dan daha cok can yakar |

FP8 icin **anlamsiz**, uygulamayin: `marlin-int8-negative-scales`,
`marlin-int8-layer-select` (yalniz W4A16 Marlin yolu), `qwen3_5-embed-quant` (yalniz
int-quantize edilmis embedding tablosu), `qwen3_5-mtp-draft-vocab` (upstream'in
`build_draft_vocab.py`'si W4A16 layout'una gore yazilmis, FP8'de dogrulanmadi).

`patch` komutu idempotent: uygulanmis patch'i atlar, uymayan patch'te dry-run'da durur ve
uygulananlari `.patches-applied` dosyasina yazar (`verify` bunu okur).

## llama.cpp tarafindan gelen farklar

`llama-turboquant/qwen3.8-27b.env` ile denklikler:

| llama.cpp | vLLM | not |
|---|---|---|
| `CACHE_TYPE_K=q8_0` / `CACHE_TYPE_V=turbo4` | `KV_CACHE_DTYPE=fp8` | vLLM'de KV format engine seviyesinde, K/V ayri secilmiyor |
| `--mmproj mmproj-F16.gguf` | yok — vision checkpoint'in icinde | `ENABLE_VISION` yeterli |
| `REASONING_FORMAT=deepseek` | `REASONING_PARSER=qwen3` | ikisi de `reasoning_content` ayirir |
| `REASONING_BUDGET=4096` | **karsiligi yok** | istek bazinda `{"reasoning_effort": "low\|medium\|high\|xhigh"}`; kapatmak icin `{"chat_template_kwargs":{"enable_thinking":false}}` |
| `CHAT_TEMPLATE_FILE=../qwen3_8_chat_template.jinja` | bos birak | o dosya GGUF tarafi icindi; FP8 checkpoint resmi template'i tasiyor |
| `TEMP` / `TOP_K` / `TOP_P` / `MIN_P` | checkpoint `generation_config.json` | vLLM onu okur; zorlamak icin `OVERRIDE_GENERATION_CONFIG` |
| `PARALLEL_SLOTS=1` | `MAX_NUM_SEQS` | vLLM continuous batching yapar, slot paylasimi ayni degil |
| `ENABLE_SLOTS` / `ENABLE_WEBUI` | yok | vLLM sadece OpenAI-uyumlu API sunar |

## Guvenlik

`HOST=0.0.0.0` ile LAN/VPN/internetten ulasilabiliyorsa **mutlaka** `API_KEY` ver ya da
reverse-proxy authentication kullan. Anahtari bu dosyaya yazip commit etme:

```bash
API_KEY=$(openssl rand -hex 24) sh ./cli.sh --env ./qwen3.8-27b-l40s.env start
```

## Uretilen dosyalar

`.gitignore` altinda: `venv/`, `upstream-syv/`, `vllm-*.log`, `vllm-*.pid`,
`.patches-applied`, `.vllm-serve-help.txt`. Model `../models/Qwen3.8-27B-FP8/` altina
iner (repo dışı).
