# StableGen RunPod Template

A self-contained RunPod template for the [StableGen](https://github.com/sakalond/StableGen)
Blender addon backend: ComfyUI plus every custom node and model StableGen needs
for SDXL texturing, Qwen Image Edit texturing, PBR decomposition, and TRELLIS.2
image/text-to-3D. You own the image and the boot script, so nothing goes stale
behind your back.

## What gets installed

Everything lands on your **network volume** (`/workspace`) on first boot, so you
pay the setup cost once. Later boots verify and launch in a couple of minutes.

| Component | Where | Size |
|---|---|---|
| ComfyUI (from RunPod image, with JupyterLab + Manager) | `/workspace/runpod-slim/ComfyUI` | in image |
| Custom nodes: IPAdapter Plus, GGUF, TRELLIS2, Marigold, StableDelight | `ComfyUI/custom_nodes/` | in image |
| SDXL stack: IPAdapter + CLIP vision models, ControlNets (depth + union + alt), Lightning/Hyper LoRAs | `ComfyUI/models/...` | ~14 GB |
| RealVisXL V5.0 fp16 checkpoint (ready-to-use SDXL base) | `ComfyUI/models/checkpoints/` | ~6.5 GB |
| Qwen Image Edit 2509: GGUF UNet (Q3_K_M), VAE, text encoder, Lightning LoRA | `ComfyUI/models/...` | ~20 GB |
| TRELLIS.2-4B weights | `ComfyUI/models/trellis2/` | ~15.4 GB |
| DinoV3 encoder (public mirror, no token needed) | `ComfyUI/models/dinov3/` | ~1.3 GB |
| BiRefNet (background removal) | HF cache on volume | ~1 GB |
| StableDelight (yoso-delight) diffusers model | `ComfyUI/models/diffusers/` | ~3.3 GB |
| Compiled comfy-env/pixi environments for TRELLIS2 | `/workspace/.ce` | ~5 GB |

Total first-boot download: roughly **60-65 GB** (volume speed dependent, expect
30-90 min) plus 10-20 min of CUDA compilation for the TRELLIS2 node the first
time. Nothing in the default set is gated: no HuggingFace token required.

## Repo layout

```
stablegen-runpod-template/
├── Dockerfile            # runpod/comfyui (pinned, cuda12.8) + pre-cloned nodes
├── start.sh              # boot script; installed as the image's /start.sh entrypoint
├── stablegen_install.py  # headless driver for StableGen's installer.py
├── build_and_push.sh     # local build helper
└── README.md
```

The image bakes in:

- `/opt/stablegen` - the StableGen repo (pinned commit) providing `installer.py`
- `/start.sh` - our boot script, installed as the image entrypoint
- `/opt/stablegen-template/` - `stablegen_install.py` (the headless driver) and `BUILD_INFO`
- `/start-runpod.sh` - RunPod's original launcher, exec'd at the end of our `/start.sh`
- `/opt/comfyui-baked/custom_nodes/` - the five custom node repos, pre-cloned

The Docker build needs **no GPU**: everything GPU-specific (CUDA extension
compilation) and every model download happens at first pod boot, because that
is the only place where the GPU and the `/workspace` volume exist.

## Build and push (one-time, from your machine)

```bash
docker login            # or: echo $GHCR_TOKEN | docker login ghcr.io -u USER --password-stdin
./build_and_push.sh docker.io/YOURUSER/stablegen-comfyui:latest
```

Useful overrides:

```bash
# New RunPod image release (check hub.docker.com/r/runpod/comfyui/tags):
BASE_TAG=1.4.1-rc.175-comfyuiv0.35.0-cuda12.8 ./build_and_push.sh ...

# Newer StableGen commit (installer.py + patches):
STABLEGEN_REF=<commit-or-tag> ./build_and_push.sh ...

# Pin a node repo to a known commit:
TRELLIS2_REF=<commit> ./build_and_push.sh ...
```

The exact commits baked into an image are printed during the build and stored
in `/opt/stablegen-template/BUILD_INFO` inside it.

## Create the RunPod template

1. RunPod console: **Save & New Template** (or edit an existing one).
2. **Container Image**: the image you pushed.
3. **Start Command**: leave it **empty**. The image takes over the container
   entrypoint: your `start.sh` is installed as `/start.sh` and runs the
   StableGen setup, then hands off to RunPod's original script (renamed to
   `/start-runpod.sh`) which starts ComfyUI, JupyterLab, FileBrowser and SSH.
   Do not set a start command: the base image uses `ENTRYPOINT ["/start.sh"]`
   and ignores extra arguments, so a template start command would silently
   never run. (This is exactly why cmd-override setups on this image go stale.)
4. **Container Disk**: 30 GB (headroom for compile jobs; caches live here).
5. **Volume**: mount a network volume at `/workspace`, 100 GB or more.
6. **Expose HTTP ports** [8188](ComfyUI), [8888](JupyterLab) and [8080](FileBrowser); TCP [22](SSH). Connect Blender
   to the pod's 8188 proxy URL (or `IP:8188`) as the StableGen server address.

Optional template env vars:

| Variable | Effect |
|---|---|
| `HF_TOKEN` | HuggingFace token. Not needed for the default set; useful if you add gated models later. |
| `STABLEGEN_TAGS` | Replace the installer package list, e.g. `core preset_essentials checkpoint_realvis trellis2` to skip Qwen. Valid tags: `core preset_essentials extended_optional pbr_marigold pbr_stabledelight checkpoint_realvis qwen_core qwen_extras qwen_nunchaku trellis2 flux2_klein` |
| `STABLEGEN_SKIP_INSTALL=1` | Skip node/model installation entirely (quick boot, debug only). |
| `STABLEGEN_SKIP_MODELS=1` | Skip the TRELLIS.2/DinoV3/BiRefNet weight prefetch. |

## First boot vs. later boots

- **First boot** (60-90 min): copies ComfyUI to the volume, applies StableGen's
  compat patches, runs the TRELLIS2 installer (compiles CUDA kernels for your
  GPU), downloads all models. Progress is visible in the pod logs.
- **Later boots** (~2 min): re-verifies installs (`hf download` resumes/no-ops
  in seconds) and starts ComfyUI.
- **Pod moved to a different GPU generation** (e.g. volume shared between a
  4090 and a 5090 pod): the boot script detects the arch change via a stamp
  file in `/workspace/.ce`, wipes the compiled envs, and rebuilds them for the
  new GPU automatically.

## Updating things

- **Update a custom node**: easiest via ComfyUI-Manager in the web UI.
  Manually: `cd /workspace/runpod-slim/ComfyUI/custom_nodes/<node> && git pull`,
  then restart the pod.
- **Update everything to a new image**: rebuild + push the image, update the
  template. Then either start a pod with a fresh volume, or delete
  `/workspace/runpod-slim/ComfyUI` on the existing volume so the new baked
  copy (with updated nodes) is copied in. Models, compiled envs, and HF cache
  on the volume are reused either way.
- **Update StableGen's installer logic** (node pins, patches): rebuild the
  image with a newer `STABLEGEN_REF`.

## Base image and ComfyUI versions

Everything is deliberately **pinned**:

- The base image `runpod/comfyui:1.4.0-comfyuiv0.35.0-cuda12.8` bakes
  ComfyUI **v0.35.0** (a release tag, not `main`), ComfyUI-Manager/KJNodes at
  pinned SHAs, torch `2.10.0+cu128` on Ubuntu 24.04 with Python 3.12.
- Upstream ComfyUI moves faster than the image (v0.4x exists upstream); the
  image only advances when RunPod cuts a new release. That is a feature for a
  backend: StableGen's workflows target whatever nodes the server has.
- Floating tags `runpod/comfyui:cuda12.8` and `:latest` always track the
  newest build. This template pins a versioned tag so behavior cannot change
  under you; bump `BASE_TAG` deliberately when you want to move.
- The image writes its pins to `/opt/comfyui-baked/.runpod-bundle-version` and
  `/opt/comfyui-runtime-constraints.txt` (torch pins). The boot script exports
  `PIP_CONSTRAINT` from the latter so no later `pip install` can disturb the
  CUDA-matched torch stack.

## How it stays standing on RunPod's image

The boot script keeps the fixes that made the old hand-rolled template work,
plus corrections for how the current ComfyUI-TRELLIS2 actually behaves:

- It runs as the container ENTRYPOINT (installed as `/start.sh`), so it
  executes on every pod start; no RunPod start command is involved.
- It creates the `.venv-cu128` (system-site-packages) itself before use,
  mirroring the base image's own logic, so the installer always runs with the
  ComfyUI interpreter.
- `PIP_CONSTRAINT` from the image keeps torch/torchvision/torchaudio pinned
  during all node requirement installs.
- `huggingface-hub` is pinned `>=1.5.0,<2.0` before installs, and re-pinned
  after, because the image's `transformers` hard-requires that range. Hub 2.x
  creeping in is what crashes ComfyUI at import with
  `ImportError: huggingface-hub>=1.5.0,<2.0 is required`.
- Compiled envs persist in `COMFY_ENV_ROOT=/workspace/.ce`; pip/pixi/uv caches
  go to ephemeral container disk so the volume stays lean.
- The base image's own upgrade logic (`.runpod-bundle-version` manifest)
  refreshes ComfyUI core and its four managed nodes when you bump `BASE_TAG`,
  while treating the StableGen nodes as user-owned and leaving them alone.
  To force a node back to the image's baked version, delete its directory
  under `custom_nodes/` and restart the pod.
- The TRELLIS.2 model directory is `ComfyUI/models/trellis2` (the node's
  current layout). The old template's `models/trellis` is dead weight.
- DinoV3 is fetched from the public `PIA-SPACE-LAB` mirror the node remaps to,
  so no gated-repo HF token dance is needed anymore.
- WAS Node Suite and GeometryPack are gone: StableGen's Blender-driven
  workflows only use ComfyUI-TRELLIS2 nodes.

## Troubleshooting

- **ComfyUI up but nodes missing**: check pod logs for the installer driver
  section; re-run it manually:
  `/workspace/runpod-slim/ComfyUI/.venv-cu128/bin/python /opt/stablegen-template/stablegen_install.py /workspace/runpod-slim/ComfyUI`
- **First TRELLIS.2 generation stalls**: the isolated env compiles on first
  node execution. Normal. Watch the pod logs; do not restart.
- **Out of memory on 24 GB GPUs**: use TRELLIS.2 1024 (non-cascade) resolution
  and lower texture sizes; Qwen GGUF Q3 is already the VRAM-friendly path.
- **`/start-runpod.sh` behavior**: the boot script ends with
  `exec /start-runpod.sh`, RunPod's original launcher (ComfyUI args from
  `/workspace/runpod-slim/comfyui_args.txt`, JupyterLab on 8888, FileBrowser
  on 8080, SSH). If ComfyUI crashes, that script keeps the container alive so
  you can debug over SSH/Jupyter.

## Blender side

Install the StableGen addon from the [releases page](https://github.com/sakalond/stablegen/releases)
(the `stablegen/` folder of the repo is the addon source), set the server
address to your pod (proxy URL or `IP:8188`), pick an architecture and
checkpoint, and generate. The addon auto-detects whether the TRELLIS.2 nodes
are available on the server.
