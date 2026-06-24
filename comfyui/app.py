"""
Krea-2-Turbo (yerel GGUF) — Gradio onyuz.

Kaynak: huggingface.co/spaces/akhaliq/Krea-2-Turbo-workflow
Orijinal ornek gr.Workflow + uzak `krea/Krea-2` HF Space API'sini kullaniyordu
(yerel GGUF YUKLEMIYORDU). Bu surum ayni boru hattini (prompt zenginlestirme ->
uretim -> PIL filtresi) korur ama uretimi YEREL ComfyUI'ye yonlendirir; ComfyUI
realrebelai/KREA-2_GGUFs TURBO Q5_K_S GGUF'unu calistirir (bkz. workflow_api.json).

ComfyUI: 127.0.0.1:8188 (COMFYUI_URL ile degistirilebilir) — yalnizca yerel.
Gradio: 0.0.0.0:8012, Caddy uzerinden /krea subpath'inde (GRADIO_ROOT_PATH=/krea).
"""

import io
import json
import os
import urllib.parse
import urllib.request

import gradio as gr
import numpy as np
from PIL import Image, ImageEnhance, ImageOps

COMFYUI_URL = os.environ.get("COMFYUI_URL", "http://127.0.0.1:8188").rstrip("/")
WORKFLOW_PATH = os.path.join(os.path.dirname(__file__), "workflow_api.json")

# --- Prompt stil sablonlari (akhaliq ornegindeki STYLES ile ayni) ---------
STYLES = {
    "None (Pass-through)": "{prompt}",
    "Photorealistic": "{prompt}, macro photography, extremely shallow depth of field, sharp focus, natural lighting, high-contrast minimal composition, warm skin tones, cinematic color palette, shot on 85mm lens, 8k resolution, photorealistic",
    "3D Toy Figure": "3D rendered matte {prompt} toy figure, stylized round anthropomorphic shape, smooth vinyl texture, studio lighting, solid vibrant background, high contrast, minimal composition, octane render, raytracing, 3d art",
    "Anime / Manga": "highly detailed digital painting of {prompt}, anime key art style, vibrant color palette, dynamic lighting, beautiful eyes, dramatic angle, concept art aesthetic, studio ghibli or makoto shinkai style",
    "Cyberpunk": "retro-futuristic cyberpunk style {prompt}, neon glow, wet streets with reflections, holographic details, cinematic lighting, dark atmosphere, blade runner aesthetic, highly detailed, 8k",
    "Ligne Claire / Minimalist": "minimalist flat-color illustration of {prompt}, clean lines, delicate paper texture, vast negative space, high-angle perspective, harmonious color palette, ligne claire style, modern vector graphic",
    "Surreal Oil Painting": "surreal dreamlike painting of {prompt}, thick impasto oil paint texture, visible coarse brushstrokes, rich color blending, atmospheric lighting, masterpiece, gallery quality",
}

DEFAULT_PROMPT = "immense rocket launch exhaust as seen from extremely close up"


def enhance_prompt(prompt: str = DEFAULT_PROMPT, style: str = "None (Pass-through)") -> str:
    """Temel prompt'u secilen stil sablonuyla zenginlestirir."""
    if not prompt:
        prompt = DEFAULT_PROMPT
    template = STYLES.get(style, "{prompt}")
    return template.replace("{prompt}", prompt)


def apply_filter(image: Image.Image, filter_type: str = "None") -> Image.Image:
    """Ureteilen gorsele PIL tabanli estetik filtre uygular (akhaliq orneginden)."""
    if image is None:
        return None
    if not isinstance(image, Image.Image):
        try:
            image = Image.fromarray(np.array(image).astype("uint8"), "RGB")
        except Exception:
            return image
    if image.mode != "RGB":
        image = image.convert("RGB")

    if filter_type == "None":
        return image
    elif filter_type == "Black & White":
        return ImageOps.grayscale(image)
    elif filter_type == "Sepia / Vintage":
        width, height = image.size
        pixels = image.load()
        for py in range(height):
            for px in range(width):
                r, g, b = pixels[px, py]
                tr = int(0.393 * r + 0.769 * g + 0.189 * b)
                tg = int(0.349 * r + 0.686 * g + 0.168 * b)
                tb = int(0.272 * r + 0.534 * g + 0.131 * b)
                pixels[px, py] = (min(tr, 255), min(tg, 255), min(tb, 255))
        return image
    elif filter_type == "High Contrast":
        return ImageEnhance.Contrast(image).enhance(1.6)
    elif filter_type == "Cool / Cyberpunk":
        r, g, b = image.split()
        r = r.point(lambda i: i * 0.8)
        b = b.point(lambda i: min(255, int(i * 1.3)))
        return Image.merge("RGB", (r, g, b))
    elif filter_type == "Warm / Golden Hour":
        r, g, b = image.split()
        r = r.point(lambda i: min(255, int(i * 1.25)))
        g = g.point(lambda i: min(255, int(i * 1.1)))
        b = b.point(lambda i: i * 0.8)
        return Image.merge("RGB", (r, g, b))
    return image


# --- ComfyUI HTTP API kostumcu ------------------------------------------
def _post_prompt(graph: dict) -> str:
    payload = json.dumps({"prompt": graph}).encode("utf-8")
    req = urllib.request.Request(
        f"{COMFYUI_URL}/prompt", data=payload, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["prompt_id"]


def _get_json(path: str):
    with urllib.request.urlopen(f"{COMFYUI_URL}{path}", timeout=30) as r:
        return json.load(r)


def _fetch_image(filename: str, subfolder: str, ftype: str) -> Image.Image:
    q = urllib.parse.urlencode({"filename": filename, "subfolder": subfolder, "type": ftype})
    with urllib.request.urlopen(f"{COMFYUI_URL}/view?{q}", timeout=60) as r:
        return Image.open(io.BytesIO(r.read())).convert("RGB")


def _build_graph(prompt_text: str, negative: str, width: int, height: int, steps: int,
                 cfg: float, seed: int) -> dict:
    with open(WORKFLOW_PATH, "r", encoding="utf-8") as f:
        g = json.load(f)
    g = {k: v for k, v in g.items() if not k.startswith("_")}  # _comment vb. ele
    g["6"]["inputs"]["text"] = prompt_text
    g["7"]["inputs"]["text"] = negative or ""
    g["9"]["inputs"]["width"] = int(width)
    g["9"]["inputs"]["height"] = int(height)
    g["8"]["inputs"]["steps"] = int(steps)
    g["8"]["inputs"]["cfg"] = float(cfg)
    g["8"]["inputs"]["seed"] = int(seed)
    return g


def generate(prompt_text: str, width: int, height: int, steps: int, cfg: float,
             seed: int, negative: str = "") -> Image.Image:
    """Yerel ComfyUI'de GGUF ile bir gorsel uretir, PIL Image dondurur."""
    import time

    if seed is None or int(seed) < 0:
        seed = int.from_bytes(os.urandom(4), "big")

    graph = _build_graph(prompt_text, negative, width, height, steps, cfg, seed)
    try:
        prompt_id = _post_prompt(graph)
    except urllib.error.URLError as e:
        raise gr.Error(f"ComfyUI'ye baglanilamadi ({COMFYUI_URL}). Calisiyor mu? Detay: {e}")

    # /history pollla — is bitince ciktilar gorunur
    deadline = time.time() + 600  # turbo + buyuk DiT: cömert timeout
    while time.time() < deadline:
        hist = _get_json(f"/history/{prompt_id}")
        if prompt_id in hist:
            outputs = hist[prompt_id].get("outputs", {})
            for node_out in outputs.values():
                for img in node_out.get("images", []):
                    return _fetch_image(img["filename"], img.get("subfolder", ""), img.get("type", "output"))
            raise gr.Error("ComfyUI is tamamlandi ama gorsel ciktisi bulunamadi.")
        time.sleep(1.0)
    raise gr.Error("ComfyUI uretimi zaman asimina ugradi (600s).")


def run_pipeline(prompt, style, filter_type, width, height, steps, cfg, seed, negative):
    """akhaliq boru hatti: zenginlestir -> uret (yerel GGUF) -> filtrele."""
    enhanced = enhance_prompt(prompt, style)
    image = generate(enhanced, width, height, steps, cfg, seed, negative)
    image = apply_filter(image, filter_type)
    return image, enhanced


# --- Gradio UI ------------------------------------------------------------
with gr.Blocks(title="Krea-2-Turbo (yerel GGUF)") as demo:
    gr.Markdown(
        "# Krea-2-Turbo — yerel GGUF\n"
        "realrebelai **Krea-2-Turbo-Q5_K_S.gguf** modelini yerel ComfyUI uzerinden calistirir. "
        "Boru hatti: prompt zenginlestirme → uretim → PIL filtresi "
        "(akhaliq/Krea-2-Turbo-workflow orneginden uyarlanmistir)."
    )
    with gr.Row():
        with gr.Column():
            prompt = gr.Textbox(label="Prompt", value=DEFAULT_PROMPT, lines=3)
            negative = gr.Textbox(label="Negative prompt", value="", lines=1)
            style = gr.Dropdown(list(STYLES.keys()), value="None (Pass-through)", label="Stil")
            filter_type = gr.Dropdown(
                ["None", "Black & White", "Sepia / Vintage", "High Contrast",
                 "Cool / Cyberpunk", "Warm / Golden Hour"],
                value="None", label="Filtre (uretim sonrasi)",
            )
            with gr.Row():
                width = gr.Slider(512, 2048, value=1024, step=64, label="Genislik")
                height = gr.Slider(512, 2048, value=1024, step=64, label="Yukseklik")
            with gr.Row():
                steps = gr.Slider(1, 30, value=8, step=1, label="Adim (turbo: 8)")
                cfg = gr.Slider(0.0, 10.0, value=1.0, step=0.1, label="CFG (turbo: 1.0)")
            seed = gr.Number(value=-1, label="Seed (-1 = rastgele)", precision=0)
            btn = gr.Button("Uret", variant="primary")
        with gr.Column():
            out_img = gr.Image(label="Sonuc", type="pil")
            out_prompt = gr.Textbox(label="Kullanilan (zenginlestirilmis) prompt", lines=3)

    btn.click(
        run_pipeline,
        inputs=[prompt, style, filter_type, width, height, steps, cfg, seed, negative],
        outputs=[out_img, out_prompt],
    )

if __name__ == "__main__":
    # GRADIO_SERVER_NAME / GRADIO_SERVER_PORT / GRADIO_ROOT_PATH env'lerini
    # cli.sh ayarlar; launch() bunlari otomatik okur (Caddy /krea subpath icin
    # GRADIO_ROOT_PATH=/krea).
    demo.queue().launch(
        server_name=os.environ.get("GRADIO_SERVER_NAME", "0.0.0.0"),
        server_port=int(os.environ.get("GRADIO_SERVER_PORT", "8012")),
    )
