#!/bin/bash
# =============================================================================
# StableGen backend boot script. This file is installed AS /start.sh in the
# image (the base image's original script is renamed to /start-runpod.sh and
# exec'd at the end), so it runs as the container ENTRYPOINT on every start.
#
# Runs on the pod with a GPU and the /workspace network volume mounted.
# Installs/repairs everything StableGen needs on top of the image's ComfyUI,
# then hands control to RunPod's original /start-runpod.sh (ComfyUI args file,
# JupyterLab, FileBrowser, SSH).
#
# Why an ENTRYPOINT takeover instead of a RunPod template "start command":
# the base image uses ENTRYPOINT ["/start.sh"], and /start.sh ignores extra
# arguments. A start command set on the template is passed as arguments and
# silently never runs. Installing our logic as /start.sh sidesteps that
# entirely; the template needs no start command at all.
#
# Design notes (learned the hard way, see the git history of the old
# trellis2 setup.sh this replaces):
#   * Compiled envs (comfy-env/pixi) live on the VOLUME (/workspace/.ce), so
#     they survive pod restarts. Caches live on ephemeral container disk.
#   * CUDA extensions are compiled per GPU arch. A network volume shared
#     between e.g. a 4090 and a 5090 pod must rebuild when the arch changes;
#     the stamp-file guard below handles that automatically.
#   * The image's transformers (system site-packages, shared into the venv)
#     only imports with a huggingface-hub version inside its declared range
#     (older images: >=1.5.0,<2.0; current: >=1.31.0,<3.0). Any unbounded pip
#     install can drag hub out of range and crash ComfyUI at import. We pin
#     the range (derived from the installed transformers) before installs AND
#     heal after.
#   * Nothing here is fatal unless ComfyUI itself cannot start: every optional
#     step warns and continues.
#
# Environment knobs (set them on the RunPod template/pod as needed):
#   HF_TOKEN                optional HuggingFace token (nothing in the default
#                           set is gated; only useful for extra private models)
#   STABLEGEN_TAGS          override the installer package tags (default:
#                           core preset_essentials extended_optional
#                           pbr_marigold pbr_stabledelight
#                           checkpoint_realvis qwen_core trellis2)
#   STABLEGEN_SKIP_INSTALL  set to 1 to skip the installer driver entirely
#   STABLEGEN_SKIP_MODELS   set to 1 to skip the TRELLIS.2 weight prefetch
# =============================================================================

echo "=== StableGen RunPod template: boot start ($(date -u +%FT%TZ)) ==="

# Record what the image bakes (base tag, ComfyUI core override, node pins).
[ -f /opt/stablegen-template/BUILD_INFO ] && sed 's/^/  /' /opt/stablegen-template/BUILD_INFO
[ -f /opt/comfyui-baked/.runpod-bundle-version ] \
  && echo "  baked bundle: $(tr '\n' ' ' < /opt/comfyui-baked/.runpod-bundle-version)"

# --- System dependencies (already in the image; cheap no-op otherwise) ------
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq wget ca-certificates git >/dev/null 2>&1

COMFYUI_PATH="/workspace/runpod-slim/ComfyUI"

# --- Self-heal: populate /workspace from the image's baked copy -------------
if [ ! -f "$COMFYUI_PATH/main.py" ]; then
  if [ -d /opt/comfyui-baked ]; then
    echo "First boot: copying baked ComfyUI (incl. StableGen nodes) to workspace..."
    rm -rf "$COMFYUI_PATH"
    mkdir -p "$(dirname "$COMFYUI_PATH")"
    cp -a /opt/comfyui-baked "$COMFYUI_PATH"
  else
    echo "WARN: no baked ComfyUI in image; cloning comfyanonymous/ComfyUI..."
    mkdir -p "$(dirname "$COMFYUI_PATH")"
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_PATH" \
      || echo "ERROR: ComfyUI clone failed"
  fi
fi

# --- Ensure the cu128 venv exists BEFORE /start-runpod.sh would create it ---
# The base image creates .venv-cu128 (system-site-packages) at runtime inside
# its own start script; the installer driver needs it earlier. Mirror the
# upstream logic. A legacy .venv (CUDA 12.4 era) is moved aside: the driver
# reinstalls our node deps into the new venv anyway.
VENV_DIR="$COMFYUI_PATH/.venv-cu128"
if [ ! -x "$VENV_DIR/bin/python" ]; then
  if [ -d "$COMFYUI_PATH/.venv" ] && [ ! -d "$COMFYUI_PATH/.venv.bak" ]; then
    echo "Moving legacy .venv aside (CUDA 12.4 era); it can be deleted later."
    mv "$COMFYUI_PATH/.venv" "$COMFYUI_PATH/.venv.bak"
  fi
  echo "Creating cu128 venv (system-site-packages)..."
  python3.12 -m venv --system-site-packages "$VENV_DIR"
  "$VENV_DIR/bin/python" -m ensurepip >/dev/null 2>&1 || true
fi

# --- Sync image-baked StableGen nodes into the workspace (offline-first) ----
# Nodes deleted from the workspace are restored from the image without
# touching GitHub. Existing (possibly newer, Manager-updated) nodes win.
for node in ComfyUI_IPAdapter_plus ComfyUI-GGUF ComfyUI-TRELLIS2 ComfyUI-Marigold ComfyUI_StableDelight_ll; do
  if [ -d "/opt/comfyui-baked/custom_nodes/$node" ] && [ ! -d "$COMFYUI_PATH/custom_nodes/$node" ]; then
    echo "Restoring baked node: $node"
    cp -a "/opt/comfyui-baked/custom_nodes/$node" "$COMFYUI_PATH/custom_nodes/$node"
  fi
done

# --- Keep pip away from the image's CUDA-pinned torch stack -----------------
# Same constraint file /start-runpod.sh exports; we need it earlier because
# the installer driver pip-installs node requirements.
if [ -f /opt/comfyui-runtime-constraints.txt ]; then
  export PIP_CONSTRAINT=/opt/comfyui-runtime-constraints.txt
  echo "Using runtime pip constraints from $PIP_CONSTRAINT"
fi

# --- Python: the cu128 venv, then system python ------------------------------
# NOTE: keep pip invocations as "$PY" -m pip ... — packing "$PY -m pip" into a
# single quoted variable makes bash treat it as one command name and every
# call dies with "No such file or directory".
PY="$VENV_DIR/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"
echo "Using python: $PY ($("$PY" --version 2>&1))"

# ---------------------------------------------------------------------------
# GPU arch detection. The compiled CUDA extensions (trellis2/geometrypack)
# must match THIS pod's GPU. We stamp the arch the envs were built for and
# force a rebuild when the volume moves between GPU generations.
# ---------------------------------------------------------------------------
COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
if [ -n "$COMPUTE_CAP" ]; then
  export TORCH_CUDA_ARCH_LIST="${COMPUTE_CAP}+PTX"
else
  echo "WARN: could not detect GPU compute capability; building multi-arch"
  export TORCH_CUDA_ARCH_LIST="8.9;9.0;12.0+PTX"
fi
echo "GPU compute capability: ${COMPUTE_CAP:-unknown} | TORCH_CUDA_ARCH_LIST=$TORCH_CUDA_ARCH_LIST"

# Caches on EPHEMERAL container disk (so they don't bloat the volume); built
# envs and model weights on the VOLUME (so they survive restarts).
export PIP_CACHE_DIR=/root/.pip-cache
export COMFY_ENV_ROOT=/workspace/.ce
export PIXI_CACHE_DIR=/root/.pixi-cache
export RATTLER_CACHE_DIR=/root/.pixi-cache
export UV_CACHE_DIR=/root/.uv-cache
export TMPDIR=/tmp
export HF_HOME=/workspace/.cache/huggingface
export MAX_JOBS=$(( $(nproc) > 8 ? 8 : $(nproc) ))
mkdir -p "$PIP_CACHE_DIR" "$COMFY_ENV_ROOT" "$PIXI_CACHE_DIR" "$UV_CACHE_DIR" "$TMPDIR" "$HF_HOME"
[ -n "${HF_TOKEN:-}" ] && export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"

# --- Volume space check (first boot writes ~65 GB of models + envs) --------
AVAIL_GB=$(df -BG --output=avail /workspace 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
if [ "${AVAIL_GB:-0}" -lt 70 ]; then
  echo "WARN: only ${AVAIL_GB} GB free on /workspace; first boot needs ~65 GB."
  echo "      Continuing anyway - downloads will fail loudly if the volume fills."
fi

# ---------------------------------------------------------------------------
# Arch-mismatch guard: if the persisted envs were compiled for a different
# GPU generation than this pod has, wipe the compiled bits so they rebuild.
# ---------------------------------------------------------------------------
ARCH_STAMP="$COMFY_ENV_ROOT/.built-for-arch"
BUILT_FOR=$(cat "$ARCH_STAMP" 2>/dev/null || echo "")
if [ -n "$COMPUTE_CAP" ] && [ -n "$BUILT_FOR" ] && [ "$BUILT_FOR" != "$COMPUTE_CAP" ]; then
  echo "GPU ARCH CHANGED: envs built for sm_${BUILT_FOR} but this pod is sm_${COMPUTE_CAP}"
  echo "Wiping compiled envs so CUDA extensions rebuild for this GPU..."
  rm -rf "$COMFY_ENV_ROOT/.pixi"
  for repo in ComfyUI-TRELLIS2 ComfyUI-GeometryPack; do
    # old comfy-env layout: per-repo _env_* dirs
    find "$COMFYUI_PATH/custom_nodes/$repo" -maxdepth 1 -type d -name "_env_*" \
      -exec rm -rf {} + 2>/dev/null
    # in-tree build artifacts from previous compiles
    find "$COMFYUI_PATH/custom_nodes/$repo" \
      \( -name "*.so" -o -name build -type d \) \
      -exec rm -rf {} + 2>/dev/null
  done
  rm -rf /root/.cache/torch_extensions /root/.triton 2>/dev/null
fi

# Persist env for manual shells (SSH/Jupyter) so a manual ComfyUI restart
# reuses the volume envs instead of rebuilding on ephemeral disk.
if ! grep -q "COMFY_ENV_ROOT" /root/.bashrc 2>/dev/null; then
  {
    echo ""
    echo "# StableGen RunPod template env"
    echo "export COMFY_ENV_ROOT=/workspace/.ce"
    echo "export HF_HOME=/workspace/.cache/huggingface"
    echo "export PIXI_CACHE_DIR=/root/.pixi-cache"
    echo "export RATTLER_CACHE_DIR=/root/.pixi-cache"
    echo "export TORCH_CUDA_ARCH_LIST=\"$TORCH_CUDA_ARCH_LIST\""
  } >> /root/.bashrc
fi

# --- Installer driver -------------------------------------------------------
# The hub pin goes FIRST: any later unbounded pip install (node requirements)
# can pull a huggingface-hub major the image's transformers cannot import
# with. The allowed range is DERIVED from the installed transformers' own
# metadata (older base images hard-required hub<2.0; the current one ships
# transformers 5.x + hub 2.x, requiring >=1.31,<3.0), so this stays correct
# whatever the base image locks.
hub_pin() {
  "$PY" - <<'EOF' 2>/dev/null
import importlib.metadata as m
for r in (m.requires("transformers") or []):
    if r.replace(" ", "").replace("_", "-").startswith("huggingface-hub"):
        print(r)
        break
EOF
}
if [ "${STABLEGEN_SKIP_INSTALL:-0}" != "1" ]; then
  echo "=== Installing StableGen components (nodes + models) ==="
  HUB_REQ="$(hub_pin)"
  if [ -n "$HUB_REQ" ]; then
    echo "Pinning ${HUB_REQ} (range required by the image's transformers)"
    "$PY" -m pip install -q "$HUB_REQ" requests tqdm \
      || echo "WARN: failed to pin huggingface-hub / install driver deps"
  else
    "$PY" -m pip install -q requests tqdm || true
  fi

  if "$PY" /opt/stablegen-template/stablegen_install.py "$COMFYUI_PATH"; then
    echo "StableGen installer driver finished OK."
  else
    echo "WARN: StableGen installer driver reported failures (see above)."
    echo "      Re-run manually once ComfyUI is up:"
    echo "      $PY /opt/stablegen-template/stablegen_install.py $COMFYUI_PATH"
  fi
else
  echo "STABLEGEN_SKIP_INSTALL=1 -> skipping installer driver"
fi

# --- Post-install hub pin heal ----------------------------------------------
# Crash signature this prevents: transformers refusing to import because a
# node install dragged huggingface-hub out of the range it accepts.
if ! "$PY" -c "import transformers" >/dev/null 2>&1; then
  HUB_REQ="$(hub_pin)"
  echo "WARN: transformers import failed -> re-pinning huggingface-hub into range"
  [ -n "$HUB_REQ" ] && "$PY" -m pip install "$HUB_REQ"
  "$PY" -c "import transformers" \
    || echo "ERROR: transformers still broken; nodes using it will fail to load"
fi

# --- comfy-kitchen in the isolated worker envs (fp8/fp4 fast paths) ---------
for envpy in "$COMFY_ENV_ROOT"/.pixi/envs/*/bin/python; do
  [ -x "$envpy" ] || continue
  "$envpy" -m pip install -q comfy-kitchen >/dev/null 2>&1 \
    || echo "NOTE: comfy-kitchen not installable in ${envpy} (optional; fp8/fp4 stays off)"
done

# --- TRELLIS.2 weight prefetch (resume-safe, no-ops when complete) ---------
# Current ComfyUI-TRELLIS2 layout (differs from the old template!):
#   microsoft/TRELLIS.2-4B      -> ComfyUI/models/trellis2/   (node's own dir)
#   DinoV3 ViT-L                -> ComfyUI/models/dinov3/model.safetensors
#                                  (node remaps the gated facebook/ repo to a
#                                  public mirror, so no HF_TOKEN needed)
#   ZhengPeng7/BiRefNet         -> HF cache (loaded via from_pretrained)
if [ "${STABLEGEN_SKIP_MODELS:-0}" != "1" ]; then
  HF_BIN="$(dirname "$PY")/hf"
  [ -x "$HF_BIN" ] || HF_BIN="$(dirname "$PY")/huggingface-cli"
  if [ -x "$HF_BIN" ]; then
    echo "=== Downloading/verifying TRELLIS.2 weights (~15.4 GB first time) ==="
    "$HF_BIN" download microsoft/TRELLIS.2-4B \
      --local-dir "$COMFYUI_PATH/models/trellis2/" \
      || echo "WARN: TRELLIS.2-4B prefetch failed; node will download on first use"
    echo "Pre-fetching BiRefNet into HF cache..."
    "$HF_BIN" download ZhengPeng7/BiRefNet \
      || echo "WARN: BiRefNet prefetch failed; node will download on first use"
    echo "Pre-fetching DinoV3 encoder (public mirror)..."
    "$HF_BIN" download PIA-SPACE-LAB/dinov3-vitl-pretrain-lvd1689m model.safetensors \
      --local-dir "$COMFYUI_PATH/models/dinov3/" \
      || echo "WARN: DinoV3 prefetch failed; node will download on first use"
  else
    echo "WARN: hf CLI not found next to $PY; skipping weight prefetch"
  fi
else
  echo "STABLEGEN_SKIP_MODELS=1 -> skipping weight prefetch"
fi

# Stamp the arch AFTER installs so a failed install retries on next boot.
[ -n "$COMPUTE_CAP" ] && echo "$COMPUTE_CAP" > "$ARCH_STAMP"

echo "=== Setup complete ($(date -u +%FT%TZ)); starting ComfyUI via RunPod /start-runpod.sh ==="
exec /start-runpod.sh
