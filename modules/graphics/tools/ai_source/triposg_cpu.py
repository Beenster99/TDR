"""Makes a car body shape from one photo with TripoSG (MIT licence), on a CPU.

    python triposg_cpu.py <out.glb> <photo.jpg> [steps=30] [seed=42]

One-off setup (Python 3.12 venv):
    git clone https://github.com/VAST-AI-Research/TripoSG  (set TRIPOSG to it)
    pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
    pip install diffusers transformers einops omegaconf scikit-image trimesh peft \
        jaxtyping typeguard opencv-python-headless rembg onnxruntime scipy
    huggingface-cli download VAST-AI/TripoSG --local-dir <weights> (set TRIPOSG_WEIGHTS)
  and in the TripoSG checkout, for a CPU:
    triposg/inference_utils.py: "from diso import DiffDMC" -> "DiffDMC = None",
        device='cuda' -> device='cpu'
    triposg/pipelines/pipeline_triposg.py: in geometric_func, decode with
        latents.to(self.vae.dtype), sampled_points=x.to(self.vae.dtype)
The background is cut out with rembg (isnet-general-use), keeping the biggest
object, and the car is centred on white at 512 px. The cut-out and the input
picture are saved next to the output. bf16 on a 4-core AMX CPU: ~5 min of
diffusion and ~10 min of surface extraction at a 512 grid.
"""
import sys, os, time
sys.path.insert(0, os.environ.get("TRIPOSG", "/root/triposg"))
import numpy as np, torch, trimesh
from PIL import Image
from rembg import remove, new_session
import triposg.schedulers.scheduling_rectified_flow, triposg.models.transformers.triposg_transformer, triposg.models.autoencoders.autoencoder_kl_triposg
from triposg.pipelines.pipeline_triposg import TripoSGPipeline
out, img = sys.argv[1], sys.argv[2]
steps = int(sys.argv[3]) if len(sys.argv) > 3 else 30
seed = int(sys.argv[4]) if len(sys.argv) > 4 else 42
torch.set_num_threads(4)
im = Image.open(img).convert("RGB")
cut = out.replace(".glb", "_cut.png")
if os.path.exists(cut):
    rgba = Image.open(cut).convert("RGBA")
else:
    rgba = remove(im, session=new_session("isnet-general-use"))
    rgba.save(cut)
a = np.array(rgba)
al = a[..., 3]
from scipy import ndimage
lab, n = ndimage.label(al > 128)
if n > 1:
    big = np.argmax(np.bincount(lab.ravel())[1:]) + 1
    a[..., 3] = np.where(lab == big, al, 0)
    al = a[..., 3]
ys, xs = np.where(al > 128)
x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
crop = a[y0:y1 + 1, x0:x1 + 1].astype(np.float32) / 255.0
rgb = crop[..., :3] * crop[..., 3:] + (1 - crop[..., 3:])        # white background
h, w = rgb.shape[:2]
s = int(max(w, h) * 1.2)
canvas = np.ones((s, s, 3), np.float32)
canvas[(s - h) // 2:(s - h) // 2 + h, (s - w) // 2:(s - w) // 2 + w] = rgb
pil = Image.fromarray((canvas * 255).astype(np.uint8)).resize((512, 512), Image.LANCZOS)
pil.save(out.replace(".glb", "_in.png"))
pipe = TripoSGPipeline.from_pretrained(os.environ.get("TRIPOSG_WEIGHTS", "/root/tsg_w")).to("cpu", torch.bfloat16)
pipe.vae.to(torch.bfloat16)
t = time.time()
with torch.no_grad():
    o = pipe(image=pil, generator=torch.Generator().manual_seed(seed), num_inference_steps=steps,
             guidance_scale=7.0, use_flash_decoder=False, dense_octree_depth=8, hierarchical_octree_depth=9).samples[0]
m = trimesh.Trimesh(o[0].astype(np.float32), np.ascontiguousarray(o[1]))
m.export(out)
print("done", out, len(m.faces), "faces", round(time.time() - t), "s")
