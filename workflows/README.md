# Workflows for the StableGen RunPod template

Ready-to-run ComfyUI workflows matching exactly what this template installs
(node pins + model manifest). All files are in **API format** — drag one onto
the ComfyUI canvas (or *Workflows → Open*) and the frontend converts it
automatically. Every model referenced below is downloaded by the installer on
first boot; nothing extra to fetch.

| File | What it does | Stack |
|---|---|---|
| `text_to_image_sdxl.json` | Text → image | RealVisXL V5.0 + SDXL Lightning 8-step LoRA (8 steps, cfg 1.5, `dpmpp_2s_ancestral`/`sgm_uniform` — StableGen's battle-tested preset) |
| `image_edit_qwen.json` | Image + instruction → edited image | Qwen Image Edit 2509 GGUF Q3_K_M + Lightning 4-step LoRA (`euler`/`simple`, cfg 1, shift 3 + CFGNorm) |
| `image_to_3d_trellis2.json` | Image → textured 3D mesh (GLB) | TRELLIS.2-4B: background removal → conditioning → shape → mesh processing → PBR texture |
| `text_to_3d_sdxl_trellis2.json` | Text → GLB in one graph | The two above chained: SDXL concept image feeds TRELLIS.2 directly |
| `text_to_motion_hymotion.json` | Text → skeletal animation | HY-Motion 1.0 (Qwen3-8B GGUF text encoder): skeleton preview frames + SMPL-H NPZ |

The TRELLIS.2 node params mirror the StableGen Blender addon's own templates
(`prompt_text_trellis2`), which run against this exact pinned node commit.

## Loading in the ComfyUI UI

1. Open the pod's ComfyUI on port **8188**.
2. Drag the JSON onto the canvas (or *Workflows → Open*). API format is
   auto-detected and converted.
3. In workflows with a `LoadImage` node, pick/upload your image, then **Run**.

For interactive 3D work you may prefer the **UI-format examples bundled with the
node** (they include `Preview3D`, `MaskPreview` and mask-editing paths). They
are already on your volume at:

```
/workspace/runpod-slim/ComfyUI/custom_nodes/ComfyUI-TRELLIS2/workflows/
├── geometry_texture.json          # image -> textured mesh (the interactive version)
├── geometry_only_{512,1024,1024_cascade,1536}.json
├── remove_background.json
├── standalone_texturing.json      # texture an existing mesh
├── refinement.json
└── mesh_audit.json
```

## Running headless (API)

Queue the text-to-image workflow with the prompt swapped:

```bash
HOST="http://<pod-ip>:8188"

# 1. queue (any input that is a plain value can be overridden inline)
python3 - <<'EOF' > prompt.json
import json
p = json.load(open("text_to_image_sdxl.json"))
p["3"]["inputs"]["text"] = "a mossy stone golem, plain gray background"
p["6"]["inputs"]["seed"] = 1234
json.dump(p, open("prompt.json", "w"))
EOF
curl -s -X POST "$HOST/prompt" -H 'Content-Type: application/json' -d @prompt.json

# 2. poll until the queue drains
curl -s "$HOST/queue" | jq '.data.queue_running | length'
```

For workflows with a `LoadImage` node, upload the image first:

```bash
curl -s -X POST "$HOST/upload/image" -F "image=@my_object.png" \
     -F "overwrite=true" -F 'subfolder=input'
# then set: p["1"]["inputs"]["image"] = "my_object.png"
```

Outputs land in `/workspace/runpod-slim/ComfyUI/output/` (grab them via
FileBrowser on port **8080**): PNGs from `SaveImage`, GLBs from
`Trellis2ExportTrimesh` under the `stablegen/...` prefix.

## Tuning cheat sheet

**Text-to-image speed/quality (swap LoRA + sampler settings together):**

| LoRA in `models/loras/` | steps | cfg | sampler/scheduler |
|---|---|---|---|
| `sdxl_lightning_8step_lora.safetensors` (default here) | 8 | 1.5 | `dpmpp_2s_ancestral`/`sgm_uniform` |
| `sdxl_lightning_4step_lora.safetensors` | 4 | 2.0 | `euler`/`sgm_uniform` |
| `Hyper-SDXL-8steps-lora.safetensors` | 8 | 1.5 | `dpmpp_2m`/`sgm_uniform` |
| `Hyper-SDXL-4steps-lora.safetensors` | 4 | 1.5 | `dpmpp_2m`/`sgm_uniform` |

**Qwen Image Edit:** 8-step variant
(`Qwen-Image-Edit-2509-Lightning-8steps-V1.0-bf16.safetensors`) is slightly
higher quality: set steps 8, keep cfg 1.

**TRELLIS.2:**

| Knob | Effect |
|---|---|
| `resolution` (`LoadTrellis2Models`) | `1024_cascade` (default, best quality) · `1024` (non-cascade — **use this on 24 GB GPUs**) · `512` fastest · `1536` experimental |
| `texture_size` (`Trellis2RasterizePBR`) | 2048 default here; 4096 for hero assets; 1024 on 24 GB GPUs |
| `low_vram` (`Trellis2RemoveBackground`) | keep `true` unless you have 32 GB+ |
| `ss/shape_guidance_strength` | 7.5 default; lower (~4) if geometry gets noisy, higher (~10) to adhere harder to the image |
| `tex_guidance_strength` | 3.0 default; 7.5 = more literal texture transfer from the input image |
| `target_face_count` (`Trellis2ProcessMesh`) | 100k default; 20–50k for game assets / web viewers |
| background | `Trellis2RemoveBackground` can be deleted if your input already has a transparent background — feed `LoadImage` outputs straight into `Trellis2GetConditioning` (image + inverted mask) |

**First TRELLIS.2 run on a fresh pod stalls for 10–20 min** while the isolated
env compiles CUDA kernels — that's normal (see the template README). Output
GLBs are PBR (albedo/normal/roughness/metallic) and drop straight into Blender.

## Text-to-motion (HY-Motion)

`text_to_motion_hymotion.json` generates skeletal animation from a prompt
("runs forward, then jumps over an obstacle"). Outputs land in
`output/hymotion/`: skeleton preview PNGs (quick sanity check) and an NPZ with
SMPL-H motion (rotations, translation, 3D keypoints).

**Getting it into Blender/Unity — three routes:**

| Route | How | Best for |
|---|---|---|
| GLB retarget **on your character** (server-side) | Add an `HYMotionExportGLB` node: feed it `motion_data` + `target_glb_path` pointing at a **Mixamo-rigged** `.glb` in `input/` (e.g. `3d/char.glb`). The output GLB keeps your mesh/materials with the animation baked in — imports directly into Blender **and** Unity. | You already have a rigged character |
| GLB from the 3D viewer | Add `HYMotionPreviewAnimation` (Three.js viewer): play/scrub, then click **Export GLB** — animated skeleton GLB, no extra deps. Then retarget onto any humanoid in Blender (Rigify/Rokoko) or Unity (Humanoid avatar auto-maps). | Skeleton-only, fastest |
| FBX | Add `HYMotionExportFBX` (needs `fbxsdkpy`; the boot script attempts it, see pod logs — GLB needs nothing). Supports the same Mixamo retarget via `custom_fbx_path`. | Maya/FBX pipelines |

**Where does a "Mixamo-rigged GLB" come from?** Rig your TRELLIS.2 mesh on
[mixamo.com](https://www.mixamo.com) (free, humanoid characters, ~1 min:
upload → auto-rig → download FBX), or take any Mixamo character and convert
to GLB. Alternatively rig on-pod with the **ComfyUI-UniRig** node
(`UniRig: Auto Rig` + `Apply Skinning`) — that rig is not Mixamo-named, so use
the viewer-export route + DCC retarget, or try its `UniRig: Apply Animation`
node (accepts Mixamo-FBX / SMPL-NPZ animations, e.g. HY-Motion's NPZ output,
applied to a UniRig-rigged FBX). UniRig's own workflow examples are on your
volume at `custom_nodes/ComfyUI-UniRig/workflows/`.

**Tuning:**

| Knob | Effect |
|---|---|
| `model_name` (`HYMotionLoadNetwork`) | `HY-Motion-1.0` (1.0B, best) · `HY-Motion-1.0-Lite` (0.46B — **use on 24 GB GPUs** together with the GGUF encoder) |
| `device_strategy` (`HYMotionLoadLLMGGUF`) | `gpu` (default, ~5 GB for Q4_K_M) · `balanced` · `cpu` (slow, frees all VRAM) |
| `duration` | 0.5–12 s per clip |
| `cfg_scale` | 5.0 default; higher follows the prompt more literally |
| `num_samples` | 1–4 variants per run |
| no GGUF? | `HYMotionLoadLLM` loads Qwen3-8B via transformers instead (auto-downloads ~16 GB; bnb 4-bit ≈ 5 GB VRAM) |
| long/complex prompts | `HYMotionLoadPrompter` + `HYMotionRewritePrompt` rewrite the prompt and estimate duration (Text2MotionPrompter, prefetched) |

**Prompting limits (upstream):** English, under ~60 words, one person, human
motions only — no animals, no scene/camera description, no multi-person
interactions, no seamless loops. Focus on limb/torso action: "a person throws
a ball with their right arm, stepping into the throw".

The first HY-Motion run on a fresh pod loads the DiT (~8 GB for the 1.0B) —
expect a slow first execution while weights stream from the volume.

## Text-to-3D prompt tips

TRELLIS.2 reconstructs *one object* from *one view*. Prompts that make good
concept images: "single object centered", "plain background", "full object
visible", "studio product photo". Use `image_edit_qwen.json` to clean up a
concept (remove background, fix artifacts, change material) before feeding it
to `image_to_3d_trellis2.json`.
