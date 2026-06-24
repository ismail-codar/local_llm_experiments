# Krea-2-Turbo — yerel GGUF (ComfyUI + Gradio)

[akhaliq/Krea-2-Turbo-workflow](https://huggingface.co/spaces/akhaliq/Krea-2-Turbo-workflow)
ornegini **yerel GGUF** ile calisacak sekilde uyarlar.

## Neden yeniden yazildi?

Orijinal HF Space, `gr.Workflow` + **uzak** `krea/Krea-2` HF Space API'sini
(`/generate`, `Model=Turbo`) kullaniyordu — yerel hicbir GGUF yuklemiyordu;
Python kismi yalnizca prompt zenginlestirme + PIL filtreleri yapiyordu.

Istenen model
[realrebelai/KREA-2_GGUFs · TURBO/Krea-2-Turbo-Q5_K_S.gguf](https://huggingface.co/realrebelai/KREA-2_GGUFs/blob/main/TURBO/Krea-2-Turbo-Q5_K_S.gguf)
ise bir **Diffusion Transformer (DiT)** olup yalnizca ComfyUI'de, ozel
`RealRebelAI/ComfyUI-GGUF_KREA-2` node'u ile calisir (`krea2` mimarisini
standart GGUF loader'lar tanimaz). Bu yuzden:

- Uretim **yerel ComfyUI**'ye (127.0.0.1:8188) tasindi (GGUF burada calisir).
- Gradio onyuzu (`app.py`) ayni boru hattini korur:
  **prompt zenginlestir → uret → PIL filtresi** — ama uretimi ComfyUI HTTP
  API'sine yapar.
- ComfyUI grafigi `workflow_api.json`, repodaki `Rebels KREA-2-TURBO.json`
  editor grafiginin **bagli** dugumlerinden turetildi (turbo: 8 adim, cfg 1.0,
  euler / simple).

## Bilesenler ve portlar

| Bilesen | Port | Notu |
|---|---|---|
| ComfyUI backend | 127.0.0.1:8188 | Yalnizca yerel, disa acilmaz |
| Gradio onyuz | 0.0.0.0:8012 | Caddy `/krea` subpath'i |
| Caddy | :7999/krea/ | `GRADIO_ROOT_PATH=/krea` + `strip_prefix` |

## Model dosyalari (install.sh indirir)

| Dosya | Kaynak | Hedef |
|---|---|---|
| `Krea-2-Turbo-Q5_K_S.gguf` (~8.8 GB) | `realrebelai/KREA-2_GGUFs` `TURBO/` | `ComfyUI/models/unet/` |
| `qwen3vl_4b_fp8_scaled.safetensors` | `Comfy-Org/Qwen3-VL` `text_encoders/` | `ComfyUI/models/text_encoders/` |
| `qwen_image_vae.safetensors` | `Comfy-Org/Qwen-Image_ComfyUI` `split_files/vae/` | `ComfyUI/models/vae/` |

## Kurulum

```sh
cd comfyui
./install.sh          # ComfyUI + krea2 node + venv'ler + agirliklar (~14 GB)
# parcali: ./install.sh comfyui | node | app | weights
```

> NVIDIA GPU yoksa install.sh CPU torch kurar; bu DiT modeli CPU'da cok yavas
> calisir / yuksek RAM ister. GPU onerilir.

## Calistirma

```sh
./cli.sh start                 # ComfyUI + Gradio
./cli.sh status
./cli.sh log comfy             # ComfyUI logu (model yuklenmesi burada gorunur)
./cli.sh log app               # Gradio logu
./cli.sh stop
```

Eris: <http://localhost:7999/krea/>

## Ipuclari

- Ilk uretim modeli RAM/VRAM'e yukler; biraz bekleyebilir. Sonrakiler hizlidir.
- 2048x2048 (workflow varsayilani) agirdir; UI varsayilani 1024x1024 yapildi.
- `COMFYUI_URL` env'i ile farkli bir ComfyUI adresi verilebilir.
