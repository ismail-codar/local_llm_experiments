---
kategori: integration
konu: TheTom/llama-cpp-turboquant fork'unu (TurboQuant KV + MTP) LocalAI'ye backend olarak bağlamanın tüm yöntemleri
olusturulma: 03-06-2026 10:13:09
commit: 7ee94d1
ilgili_dosyalar:
  - local-ai/install.sh
  - local-ai/test.md
  - llama-turboquant/install.sh
  - llama-turboquant/start.sh
  - llama-turboquant/swap.yaml
  - llama-turboquant/README.md
anahtar_kelimeler: [localai, llama-cpp, turboquant, grpc-server, external-backends, backend-gallery, mtp, kv-cache, llama-swap]
---

# LocalAI'ye TurboQuant llama.cpp Fork'unu Backend Olarak Bağlama

## 🎯 Hızlı Referans

- **Servis:** LocalAI (`localai/localai:latest-gpu-nvidia-cuda-13`, Docker) — `local-ai/install.sh:6`
- **Ne için kullanılıyor:** OpenAI uyumlu tek `/v1` ucu arkasında yerel modelleri sunmak (port `8000` → konteyner `8080`) — `local-ai/install.sh:2`. Şu an `embeddinggemma-300m-GGUF` ve `Qwen3.6-35B-A3B-MTP-GGUF` modelleri çağrılıyor — `local-ai/test.md:5,14`
- **Bağlamak istenen backend:** `TheTom/llama-cpp-turboquant` fork'undan derlenen `llama-server` (TurboQuant `turbo3/turbo4` KV cache + MTP speculative decoding) — `llama-turboquant/install.sh:26-48`
- **Auth yöntemi:** Yok (varsayılan). LocalAI `API_KEY` env, fork tarafı `--api-key` ile ayrı korunur — `llama-turboquant/start.sh:71,152-154`
- **Kritik mimari engel:** LocalAI'nin llama.cpp backend'i bir **gRPC sunucusudur** (`grpc-server`), fork ise **HTTP/OpenAI sunucusu** olan `llama-server` üretir — `llama-turboquant/install.sh:48`. İkisi **aynı binary değildir**; doğrudan "düşür-çalıştır" mümkün değil. Aşağıdaki 4 yöntem bu boşluğu kapatır.
- **Giriş noktaları (LocalAI → fork):**
  - gRPC backend kaydı: `--external-grpc-backends "<ad>:<uri>"` / `EXTERNAL_GRPC_BACKENDS` env
  - Model seçimi: model YAML'ında `backend: <ad>`

> **Karar özeti:** Engelin sebebi binary tipi farkıdır (gRPC vs HTTP). "Tüm yöntemler" = (1) fork'u LocalAI gRPC backend'i olarak derle, (2) OCI backend galerisi olarak paketle, (3) bundled backend binary'sini volume ile ez, (4) gerçek backend yerine fork'un kendi OpenAI ucunu proxy'le. Doğruluk sırası: 1 ≈ 2 > 3 > 4.

---

## 🔐 Kimlik Doğrulama ve Credential Yönetimi

- LocalAI konteyneri `--gpus all` ve `$PWD/:/models` + `$PWD/data:/data` mount'ları ile açılır; varsayılan auth yoktur — `local-ai/install.sh:3-5`. Auth gerekiyorsa `API_KEY`/`LOCALAI_API_KEY` env eklenir (bu repoda set edilmemiş).
- Fork tarafı `llama-server`, dışa açıkken (`0.0.0.0`) `--api-key` ile korunabilir; boşsa geçilmez — `llama-turboquant/start.sh:69-71,152-154`.
- llama-swap düzeyinde anahtar: `swap.yaml` → `apiKeys: ["sk-...", "${env.API_KEY}"]` — `llama-turboquant/README.md:233-243`.
- **Önemli:** Backend'i gRPC ile bağladığında (Yöntem 1/2/3) **istemci sadece LocalAI'nin auth'unu görür**; fork'un kendi `--api-key`'i devre dışıdır çünkü gRPC üzerinden çağrılır, HTTP `/v1` ucu kullanılmaz.

---

## 📡 Kullanılan Endpoint'ler / SDK Metodları (LocalAI ↔ Backend sözleşmesi)

| Sözleşme | Ne için | Nerede |
|---|---|---|
| gRPC backend interface (`grpc-server`) | LocalAI'nin llama.cpp modellerini sürdüğü asıl protokol | LocalAI repo `backend/cpp/llama-cpp/grpc-server.cpp` |
| `run.sh` (konteyner giriş noktası) | OCI backend image'inin çalıştırma girişi | LocalAI backend galeri sözleşmesi |
| `--external-grpc-backends "ad:uri"` | Harici/özel backend kaydı (dosya yolu **veya** `host:port`) | LocalAI CLI / `EXTERNAL_GRPC_BACKENDS` env |
| model YAML `backend: <ad>` | Bir modeli belirli backend'e yönlendirir | `/models/<model>.yaml` |
| Fork `llama-server` `/v1/*` (HTTP) | Fork'un kendi OpenAI ucu — gRPC değil | `llama-turboquant/start.sh:159-180` |

**LocalAI model YAML'ında llama.cpp tarafına geçen alanlar** (doğrulandı): `backend`, `context_size`, `threads`, `gpu_layers`, `f16`, `mmap`, `cache_type_k`, `cache_type_v`.

> `cache_type_k` / `cache_type_v` alanlarının LocalAI YAML'ında bulunması kritik bir kolaylıktır: backend binary'si TurboQuant fork'u ise bu alanlara `turbo4`/`turbo3` yazıp KV cache özelliğini YAML'dan sürebilirsin — **eğer** grpc-server bu değeri llama.cpp'ye aynen geçiriyorsa (bkz. 🩺 Eksiklikler).

---

## 🧩 Yöntemler (4 yaklaşım)

### Yöntem 1 — Fork'u LocalAI gRPC backend'i olarak derle (en doğru)

LocalAI'nin gerçek backend'i `llama-server` değil, `backend/cpp/llama-cpp/grpc-server.cpp`'dir. Bu wrapper'ı **TurboQuant fork'unun kaynak ağacına karşı** derlersin; sonuç, TurboQuant çekirdeğini konuşan bir gRPC binary'sidir.

Üst düzey adımlar:

1. Fork'u derle (zaten mevcut) — `llama-turboquant/install.sh:38-45`. CUDA 13.0, arch=89 (L40S).
2. LocalAI kaynağını al, `backend/cpp/llama-cpp` Makefile'ında `LLAMA_VERSION`/submodule'ü TurboQuant fork'una yönlendir (`git clone https://github.com/TheTom/llama-cpp-turboquant.git` + `feature/turboquant-kv-cache` — `llama-turboquant/install.sh:26,31`).
3. `grpc-server`'ı bu kaynakla derle (aynı CUDA bayrakları: `-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=89`).
4. Kaydet ve modele bağla:

```sh
# gRPC backend'i kayıtla (dosya yolu VEYA host:port)
./local-ai --external-grpc-backends "turboquant:/opt/backends/grpc-server"
# veya zaten ayakta bir gRPC süreci varsa:
./local-ai --external-grpc-backends "turboquant:127.0.0.1:50051"
```

Docker'da env ile (mevcut kurulumun konteyner tabanlı olduğu için tercih edilen yol — `local-ai/install.sh:1`):

```sh
docker run -ti --name local-ai \
  -p 8000:8080 --gpus all \
  -v "$PWD/:/models" -v "$PWD/data:/data" \
  -v "$PWD/../llama-turboquant/grpc-server:/opt/backends/grpc-server" \
  -e EXTERNAL_GRPC_BACKENDS="turboquant:/opt/backends/grpc-server" \
  localai/localai:latest-gpu-nvidia-cuda-13
```

Model YAML (`/models/qwen36-turbo.yaml`):

```yaml
name: Qwen3.6-35B-A3B-MTP-GGUF   # test.md'deki "model" alanıyla eşleşmeli (local-ai/test.md:14)
backend: turboquant
parameters:
  model: Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL.gguf   # /models altına koy
context_size: 262144
gpu_layers: 99
f16: true
mmap: false
cache_type_k: turbo4
cache_type_v: turbo4
```

- **Artı:** Tek `/v1` ucu (8000), LocalAI'nin model yönetimi/galeri/embeddings ekosistemi korunur.
- **Eksi:** MTP bayrakları (`--spec-type draft-mtp`, `--spec-draft-n-max` — `llama-turboquant/start.sh:175-176`) standart `grpc-server.cpp`'de **muhtemelen yoktur**; geçirmek için grpc-server'a patch gerekir (bkz. 🩺).

### Yöntem 2 — OCI backend image + galeri (LocalAI v3 backend sistemi)

Yeni LocalAI'de backend'ler kurulabilir OCI konteyner image'larıdır; `run.sh` giriş noktası şarttır.

1. Yöntem 1'in `grpc-server` binary'sini bir konteynere koy, üst seviyeye `run.sh` ekle (gRPC sunucusunu başlatır).
2. Registry'ye it:
   ```sh
   docker build -t quay.io/icodar/turboquant-backend:latest .
   docker push quay.io/icodar/turboquant-backend:latest
   ```
3. Galeriyi tanıt ve/veya ön-kur:
   ```sh
   export LOCALAI_BACKEND_GALLERIES='[{"name":"icodar","url":"https://raw.githubusercontent.com/icodar/repo/main/backends"}]'
   export LOCALAI_EXTERNAL_BACKENDS="turboquant-backend"
   local-ai run
   ```
   Galeri YAML'ı `name`, `uri` (OCI image yolu), `alias`, opsiyonel `tags` ister.
4. UI → **Backends** sekmesinden de aratıp tek tıkla kurulabilir/silinebilir.
5. Model YAML'ında `backend: turboquant-backend`.

- **Artı:** Tekrarlanabilir/taşınabilir, UI ile yönetim, çok makineye dağıtım.
- **Eksi:** Yöntem 1'in tüm derleme emeği + image paketleme + registry yükü. MTP patch sorunu burada da geçerli.

### Yöntem 3 — Bundled backend binary'sini volume ile ez

LocalAI imajındaki hazır llama.cpp backend binary'sinin üstüne, fork'tan derlenmiş `grpc-server`'ı mount et.

```sh
docker run ... \
  -v "$PWD/../llama-turboquant/grpc-server:/usr/share/local-ai/backends/llama-cpp/grpc-server" \
  localai/localai:latest-gpu-nvidia-cuda-13
```

(Konteyner içindeki gerçek backend yolu sürüme göre değişir; `docker exec local-ai find / -name 'grpc-server' 2>/dev/null` ile doğrula.)

- **Artı:** Model YAML'ı `backend: llama-cpp` kalır; ekstra kayıt yok.
- **Eksi:** En kırılgan yöntem. Image güncellenince ABI/yol kayar; sessizce yanlış binary çalışabilir. Sadece sabit, pinlenmiş bir dağıtımda kullan.

### Yöntem 4 — Gerçek backend yerine fork'un OpenAI ucunu proxy'le (backend DEĞİL)

Fork zaten OpenAI uyumlu `/v1` sunar (`llama-turboquant/start.sh:159-180`) veya `llama-swap` arkasında çok-model router olur (`llama-turboquant/run-swap.sh`, `swap.yaml`). LocalAI'nin inference motorunu hiç kullanmadan, fork'un `8001` ucunu öne koyabilirsin.

- Repo'da hazır bir reverse proxy var: `caddy-server/Caddyfile` (bu commit'te değişik). `/v1/*` isteklerini doğrudan `127.0.0.1:8001`'e yönlendir; embeddings gibi diğer modelleri LocalAI'de tut.
- TurboQuant + MTP'nin **tam** özellik seti (turbo cache + `draft-mtp` + 256K ctx) hiçbir patch olmadan çalışır — `llama-turboquant/start.sh:40,55-56,175-176`.

- **Artı:** Sıfır derleme/patch; fork'un tüm özellikleri birebir. En hızlı çözüm.
- **Eksi:** Teknik olarak "LocalAI backend'i" değildir; LocalAI'nin model galerisi/grpc yönetimi bu modele uygulanmaz. Tek `/v1` görüntüsü proxy katmanından gelir, LocalAI'den değil.

---

## 🧩 Veri Eşlemeleri (fork bayrağı → LocalAI YAML)

| Fork bayrağı (`start.sh` / `swap.yaml`) | LocalAI YAML karşılığı | Durum |
|---|---|---|
| `-m <gguf>` `start.sh:160` | `parameters.model` | ✅ doğrudan |
| `-c 262144` `start.sh:40,164` | `context_size: 262144` | ✅ doğrudan |
| `-ngl 99` `start.sh:159-161` | `gpu_layers: 99` | ✅ doğrudan |
| `--no-mmap` `start.sh:178` | `mmap: false` | ✅ doğrudan |
| `--cache-type-k turbo4` `start.sh:173` | `cache_type_k: turbo4` | ⚠️ grpc-server passthrough'una bağlı |
| `--cache-type-v turbo4` `start.sh:174` | `cache_type_v: turbo4` | ⚠️ aynı |
| `--mmproj <f16>` `start.sh:156` | `mmproj:` (LocalAI multimodal) | ⚠️ doğrula |
| `--spec-type draft-mtp` `start.sh:175` | **karşılığı yok** | ❌ patch gerekir |
| `--spec-draft-n-max 6` `start.sh:176` | **karşılığı yok** | ❌ patch gerekir |
| `--reasoning-budget 4096` `start.sh:177` | **karşılığı yok** | ❌ patch/atla |
| `--jinja` `start.sh:168` | (LocalAI kendi template motoru) | ↪️ farklı yol |

> Bu tablo Yöntem 1/2/3'ün gerçek sınırını gösterir: **MTP ve reasoning bütçesi standart gRPC sözleşmesinde yoktur.** Bunlar projenin başlıca değer önerisi (`README.md:288-340`) olduğundan, ya grpc-server'ı patch'le ya da bu özellikler kritikse **Yöntem 4**'ü seç.

---

## 🔄 Retry, Timeout, Rate Limit Stratejileri

- Cold start uzundur: 256K ctx + MTP yüklemesi dakikalar alabilir; llama-swap tarafı `healthCheckTimeout: 600` kullanır — `llama-turboquant/swap.yaml:9`. LocalAI gRPC backend'i için de model yükleme timeout'unu yükselt (LocalAI `--single-active-backend` / model `idle` ayarları), aksi halde ilk istek timeout'a düşer.
- VRAM tek L40S 48GB'de tek model sınırı: ~42-45 GB — `llama-turboquant/README.md:436`. LocalAI birden çok backend'i aynı anda canlı tutmaya çalışırsa OOM olur; **tek aktif backend** modunu zorla.
- llama-swap `globalTTL: 1800` ile 30 dk boştaki modeli unload eder — `swap.yaml:13`. LocalAI gRPC yolunda bu otomatik unload yoktur; eşdeğer davranış için LocalAI idle timeout'u ayarla.

---

## ⚠️ Bilinen Sorunlar ve Gotcha'lar

- **`llama-server` ≠ `grpc-server`.** Fork `build/bin/llama-server` üretir (`install.sh:48`); LocalAI bunu doğrudan backend olarak kullanamaz. Yöntem 1/2/3 hepsi `grpc-server`'ın fork kaynağıyla **yeniden derlenmesini** gerektirir.
- **MTP bayrak adı sürüm bağımlı.** Yeni: `--spec-type draft-mtp`, eski fork: `mtp`. `start.sh` `--help` çıktısından otomatik seçer — `start.sh:129-137`. grpc-server'a patch atarken hangi adı geçireceğini build'e göre belirle.
- **GGUF dosya adı çakışması.** Unsloth MTP'li ve MTP'siz repolar aynı adı kullanır; `start.sh` yerel adı `-MTP-` ile işaretler — `start.sh:27-29`. LocalAI YAML'ında `parameters.model`'i **MTP'li** dosyaya işaret ettir, yoksa `context type MTP requested but model doesn't contain MTP layers` hatası — `README.md:421`.
- **Port çakışması.** LocalAI 8000 (`install.sh:2`), fork/swap 8001 (`start.sh:13`). Yöntem 4'te ikisi yan yana çalışır; Yöntem 1-3'te fork'un HTTP sunucusu hiç ayağa kalkmaz (gRPC kullanılır).
- **CUDA arch uyumu.** Fork arch=89 (L40S) ile derli — `install.sh:40`. LocalAI imajı CUDA 13 (`install.sh:6`); grpc-server'ı da arch=89 + CUDA 13 ile derle ki ABI uyumlu olsun.
- **`test.md`'deki model adları YAML `name` ile eşleşmeli.** İstemci `model: "Qwen3.6-35B-A3B-MTP-GGUF"` gönderiyor (`test.md:14`); LocalAI model YAML'ında `name:` bu değerle birebir olmalı.

---

## 🔧 Tipik Değişiklik Senaryoları

- **Sadece "çalışsın, MTP şart değil" istiyorsan:** Yöntem 1, model YAML'a `cache_type_k/v: turbo4` ekle, MTP'yi atla.
- **MTP + turbo cache tam istiyorsan:** Yöntem 4 (Caddy proxy → fork `8001`). Patch'siz tüm özellikler.
- **Çok makineye dağıtım / takım kullanımı:** Yöntem 2 (OCI galeri).
- **MTP'yi gRPC'ye taşımak istiyorsan:** LocalAI `grpc-server.cpp`'de `predict`/`load` parametre eşlemesine `spec_type` ve `spec_draft_n_max` ekle, model YAML'a `options:` listesiyle geçir (LocalAI'nin serbest `options` alanı varsa). Önce passthrough'u doğrula.

---

## 🔌 Bağımlılıklar

**İç bağımlılıklar:**
- `llama-turboquant/install.sh` — fork derleme; `build/bin/llama-server` üretir (`install.sh:48`)
- `llama-turboquant/start.sh` — tek-model çalıştırıcı, tüm bayrak referans kaynağı
- `llama-turboquant/swap.yaml` + `run-swap.sh` — çok-model router (Yöntem 4)
- `caddy-server/Caddyfile` — reverse proxy (Yöntem 4)

**Dış bağımlılıklar:**
- LocalAI imajı `localai/localai:latest-gpu-nvidia-cuda-13` — `local-ai/install.sh:6`
- `TheTom/llama-cpp-turboquant` (`feature/turboquant-kv-cache`) — `install.sh:26,31`
- LocalAI kaynağı (`mudler/LocalAI`, `backend/cpp/llama-cpp`) — Yöntem 1/2 için derleme
- CUDA 13.0 + nvcc, CMake, build-essential — `install.sh:8-21`
- Docker + NVIDIA Container Toolkit (`--gpus all`) — `local-ai/install.sh:3`

**Ortam değişkenleri:**
- `EXTERNAL_GRPC_BACKENDS` / `--external-grpc-backends` — özel backend kaydı (zorunlu, Yöntem 1)
- `LOCALAI_BACKEND_GALLERIES` — galeri kaynağı (Yöntem 2)
- `LOCALAI_EXTERNAL_BACKENDS` — ön-kurulacak backend listesi (Yöntem 2)
- `API_KEY` — fork tarafı opsiyonel auth (`start.sh:71`); swap tarafı `${env.API_KEY}` (`README.md:237`)

## 🧪 Testler

Bu alan için otomatik test bulunmamaktadır. Manuel doğrulama (her yöntem sonrası):

```sh
# 1) Model listesinde görünüyor mu (LocalAI, port 8000)
curl -s http://localhost:8000/v1/models | jq

# 2) Chat (test.md'deki örnekle aynı) — local-ai/test.md:11-22
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen3.6-35B-A3B-MTP-GGUF","messages":[{"role":"user","content":"Merhaba dünya!"}]}'

# 3) MTP gerçekten çalışıyor mu (sadece Yöntem 4 veya patch'li gRPC)
tail -f llama-turboquant/llama-server.log | grep -E "drafted=|accepted="   # README.md:404-410
```
`accepted/drafted` oranı %50 üstündeyse MTP net kazanç sağlıyor — `README.md:410`.

## 📝 Notlar

- Mevcut `local-ai/install.sh` tek satırlık bir `docker run`'dır; backend kaydı için ya bu komuta `-e EXTERNAL_GRPC_BACKENDS=...` + volume eklenmeli ya da bir `docker-compose.yml`'e taşınmalı.
- `test.md`'deki host `10.198.15.173` — LocalAI uzak bir sunucuda (L40S host) çalışıyor; yöntem seçiminde ağ/port (8000 vs 8001) buna göre planlanmalı.
- Fork'un asıl değeri (TurboQuant KV + MTP) standart gRPC sözleşmesinin dışında kaldığı için, "LocalAI backend'i" hedefi ile "fork'un tüm özellikleri" hedefi kısmen çelişir. Karar bu trade-off üzerinedir.

## 🩺 Eksiklikler, Yanlışlıklar ve İyileştirme Önerileri

- **Bulgu:** MTP/speculative ve `--reasoning-budget` LocalAI gRPC sözleşmesinde yok; Yöntem 1-3 bu özellikleri sessizce düşürür.
  - **Etki:** Projenin ana hız avantajı (1.5–2.0× — `README.md:439`) kaybolur, ama hata vermeden "çalışıyor" görünür → yanıltıcı.
  - **Öneri:** Kritikse Yöntem 4'ü seç; değilse grpc-server'a `spec_type`/`spec_draft_n_max` parametre patch'i uygula ve passthrough'u `drafted=/accepted=` logu ile doğrula.
  - **Referans:** `llama-turboquant/start.sh:175-177`, `README.md:296-301`

- **Bulgu:** `cache_type_k/cache_type_v`'nin LocalAI grpc-server'da `turbo3/turbo4` gibi **fork'a özgü** değerleri kabul edip etmediği doğrulanmadı; upstream grpc-server yalnızca `q4_0`,`q8_0`,`f16` vb. enum'ları tanıyabilir.
  - **Etki:** YAML'a `turbo4` yazılsa bile backend reddedip `f16`'ya düşebilir → TurboQuant devre dışı, fark edilmez.
  - **Öneri:** grpc-server'da KV cache tipi parse koduna fork'un `turbo*` enum'larının eklendiğini kaynaktan doğrula; gerekirse patch'le.
  - **Referans:** `llama-turboquant/start.sh:55-56,173-174`

- **Bulgu:** `local-ai/install.sh` hiçbir backend kaydı/volume içermiyor; doküman dışı el ile değişiklik gerektirir.
  - **Etki:** "Kurulumu çalıştırdım ama backend görünmüyor" tuzağı.
  - **Öneri:** Seçilen yöntem netleşince `install.sh`'ı (veya bir compose dosyasını) `EXTERNAL_GRPC_BACKENDS` + volume mount ile güncelle.
  - **Referans:** `local-ai/install.sh:1-6`

- **Bulgu:** LocalAI'nin konteyner içi backend dosya yolu (Yöntem 3) sürüme bağlı ve belgelenmemiş.
  - **Etki:** Volume override yanlış yola binerse sessizce bundled binary çalışır.
  - **Öneri:** `docker exec local-ai find / -name grpc-server` ile yolu pinle; image tag'ini `latest` yerine sabit sürüme çek.
  - **Referans:** `local-ai/install.sh:6`

## 🤖 Yeniden Değerlendirme İçin LLM Prompt'u

```text
Bu dokümanı temel alarak "TurboQuant llama.cpp fork'unu LocalAI'ye backend olarak bağlama" alanını yeniden değerlendir.

Odaklan:
1. EN KRİTİK doğrulama: LocalAI'nin gRPC llama.cpp backend'i (mudler/LocalAI, backend/cpp/llama-cpp/grpc-server.cpp) hangi
   model YAML alanlarını gerçekten llama.cpp'ye geçiriyor? Özellikle:
   - cache_type_k / cache_type_v "turbo3"/"turbo4" gibi fork'a özgü değerleri kabul ediyor mu, yoksa enum reddi mi var?
   - spec-type / spec-draft-n-max / reasoning-budget'ı geçirmenin bir yolu var mı (options listesi vb.)?
   Bunu LocalAI kaynağından (güncel sürüm) doğrula; doğrulayamıyorsan açıkça "doğrulanamadı" yaz.
2. "llama-server vs grpc-server" ayrımının hâlâ geçerli olduğunu LocalAI'nin güncel backend mimarisinde teyit et
   (v3 backend galeri sistemi llama-server tabanlı bir backend sunmuş olabilir mi?).
3. local-ai/install.sh ve llama-turboquant/start.sh:159-180'deki bayrakları tekrar oku; Veri Eşlemeleri tablosundaki
   her satırı kodda/dokümanda doğrula, yanlışları ayıkla.
4. 4 yöntemin doğruluk sıralamasını (1≈2 > 3 > 4) tekrar değerlendir; özellikle MTP'nin korunması ölçütüyle.
5. Sonuçta: Hızlı Referans'ı daha uygulanabilir hale getir, doğrulanan/çürütülen bulguları işaretle, yeni gotcha ekle.

Her önemli iddiayı dosya:satır referansı (bu repo) veya LocalAI kaynak yolu ile destekle.
```

---

*Bu doküman `/doc` komutu ile otomatik üretilmiştir. Kategori: `integration`. Kod değiştiğinde güncellenmelidir.*
