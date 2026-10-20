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
#   STABLEGEN_SKIP_MOTION   set to 1 to skip the text-to-animation add-on
#                           (ComfyUI-HY-Motion1 + ComfyUI-UniRig nodes, their
#                           deps/envs and the HY-Motion/UniRig weight prefetch)
# =============================================================================

# Section header with a UTC timestamp: makes every boot log self-profiling
# (how long the copy / installer / downloads / env builds each took).
phase() { echo "=== $* [$(date -u +%H:%M:%SZ)] ==="; }
BOOT_SECONDS=$SECONDS

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
    phase "First boot: copying baked ComfyUI (incl. StableGen nodes) to workspace"
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
  # ensurepip bundles an old pip (24.x on Python 3.12); a current one avoids
  # old-resolver/metadata quirks in the constrained node installs. Runs once
  # per fresh venv only.
  "$VENV_DIR/bin/python" -m pip install -q --upgrade pip >/dev/null 2>&1 || true
fi

# --- Sync image-baked StableGen nodes into the workspace (offline-first) ----
# Nodes deleted from the workspace are restored from the image without
# touching GitHub. Existing (possibly newer, Manager-updated) nodes win.
for node in ComfyUI_IPAdapter_plus ComfyUI-GGUF ComfyUI-TRELLIS2 ComfyUI-Marigold ComfyUI_StableDelight_ll ComfyUI-HY-Motion1 ComfyUI-UniRig; do
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

# Locate the HuggingFace CLI. venv-local first (in case hub was installed
# into the venv), then PATH: with --system-site-packages the pin step usually
# resolves hub from system dist-packages as "already satisfied", so the entry
# points land in /usr/local/bin -- NOT next to the venv python. Without the
# PATH fallback every weight prefetch would silently skip.
hf_bin() {
  local b
  for b in "$(dirname "$PY")/hf" "$(dirname "$PY")/huggingface-cli" \
           "$(command -v hf 2>/dev/null || true)" \
           "$(command -v huggingface-cli 2>/dev/null || true)"; do
    [ -n "$b" ] && [ -x "$b" ] && { echo "$b"; return 0; }
  done
  return 1
}

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
  for repo in ComfyUI-TRELLIS2; do
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
  phase "Installing StableGen components (nodes + models)"
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
  if HF_BIN="$(hf_bin)"; then
    phase "Downloading/verifying TRELLIS.2 weights (~15.4 GB first time)"
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
    echo "WARN: no hf/huggingface-cli CLI found (venv bin or PATH); skipping weight prefetch"
  fi
else
  echo "STABLEGEN_SKIP_MODELS=1 -> skipping weight prefetch"
fi

# ---------------------------------------------------------------------------
# Motion add-on: text-to-animation + auto-rigging.
#
#   ComfyUI-HY-Motion1 (jtydhr88) - HY-Motion 1.0 (Tencent Hunyuan): text ->
#     skeletal human motion, exports GLB (skeleton animation) / FBX / NPZ.
#   ComfyUI-UniRig (PozzettiAndrea) - UniRig + Make-It-Animatable: skeleton +
#     skin weights for arbitrary meshes (e.g. TRELLIS.2 output), pose
#     manipulation, apply-animation.
#
# Runs AFTER the installer driver so it inherits the settled comfy-env pin.
# Neither node is part of StableGen's installer tags; this section owns them.
#
# comfy-env note: UniRig's requirements.txt asks for comfy-env==0.4.1, but its
# comfy-env-root.toml uses the same 0.3 schema ([node_reqs]/[cuda]) as
# TRELLIS2's, so its install.py is run under the existing 0.3.x pin and the
# pin line is stripped from its venv requirements. Do NOT let anything upgrade
# comfy-env past 0.4.25 (schema hard-reject; see installer driver notes).
#
# Nothing here is fatal: every step warns and continues.
# ---------------------------------------------------------------------------
if [ "${STABLEGEN_SKIP_MOTION:-0}" != "1" ]; then
  phase "Motion add-on: ComfyUI-HY-Motion1 (text-to-motion) + ComfyUI-UniRig (auto-rig)"

  # --- ComfyUI-HY-Motion1: venv-level deps ---------------------------------
  # Pure-Python (torch is protected by PIP_CONSTRAINT). fbxsdkpy (optional,
  # FBX export only - GLB export needs nothing extra) lives on an extra index
  # and is attempted separately so a failure cannot break the rest.
  HYMOTION_NODE="$COMFYUI_PATH/custom_nodes/ComfyUI-HY-Motion1"
  if [ -d "$HYMOTION_NODE" ]; then
    grep -vE '^(--extra-index-url|fbxsdkpy)' "$HYMOTION_NODE/requirements.txt" \
      > /tmp/hymotion-reqs.txt || true
    "$PY" -m pip install -q -r /tmp/hymotion-reqs.txt \
      || echo "WARN: HY-Motion pip requirements failed (node may still work)"
    "$PY" -m pip install -q fbxsdkpy \
      --extra-index-url https://gitlab.inria.fr/api/v4/projects/18692/packages/pypi/simple \
      || echo "NOTE: fbxsdkpy not installable -> HY-Motion FBX export disabled (GLB/NPZ export unaffected)"
  else
    echo "WARN: $HYMOTION_NODE missing; skipping its deps"
  fi

  # --- ComfyUI-UniRig: venv deps (minus the comfy-env pin) + isolated env --
  UNIRIG_NODE="$COMFYUI_PATH/custom_nodes/ComfyUI-UniRig"
  if [ -d "$UNIRIG_NODE" ]; then
    grep -viE '^\s*comfy-env' "$UNIRIG_NODE/requirements.txt" \
      > /tmp/unirig-reqs.txt || true
    "$PY" -m pip install -q -r /tmp/unirig-reqs.txt \
      || echo "WARN: UniRig venv requirements failed (node may still work)"
    echo "Building/verifying UniRig isolated env (comfy-env/pixi; first build takes a while)..."
    ( cd "$UNIRIG_NODE" && "$PY" install.py ) \
      || echo "WARN: UniRig install.py failed. Re-run once ComfyUI is up:" \
           "cd $UNIRIG_NODE && $PY install.py"
  else
    echo "WARN: $UNIRIG_NODE missing; skipping its install"
  fi

  # --- Motion weights -------------------------------------------------------
  # Layouts the nodes expect (see ComfyUI-HY-Motion1 README / nodes.py):
  #   tencent/HY-Motion-1.0      -> models/HY-Motion/ckpts/tencent/{HY-Motion-1.0,HY-Motion-1.0-Lite}/
  #   openai/clip-vit-large-...  -> models/HY-Motion/ckpts/clip-vit-large-patch14/   (text enc., CLIP side)
  #   Qwen/Qwen3-8B-GGUF Q4_K_M  -> models/HY-Motion/ckpts/GGUF/  (low-VRAM LLM encoder; 'gguf' pip pkg
  #                                                               is already present via ComfyUI-GGUF)
  #   Text2MotionPrompter        -> HF cache (prompt rewrite + duration estimate; auto-download fallback)
  #   VAST-AI/UniRig             -> HF cache (skeleton + skin ckpts; node's Load Model downloads on use)
  if [ "${STABLEGEN_SKIP_MODELS:-0}" != "1" ]; then
    if HF_BIN="$(hf_bin)"; then
      phase "Downloading/verifying motion weights (~18 GB first time)"
      "$HF_BIN" download tencent/HY-Motion-1.0 \
        --include "HY-Motion-1.0/*" "HY-Motion-1.0-Lite/*" \
        --local-dir "$COMFYUI_PATH/models/HY-Motion/ckpts/tencent/" \
        || echo "WARN: HY-Motion ckpt prefetch failed; node will download on first use"
      "$HF_BIN" download openai/clip-vit-large-patch14 \
        --include "*.json" "*.txt" "model.safetensors" \
        --local-dir "$COMFYUI_PATH/models/HY-Motion/ckpts/clip-vit-large-patch14/" \
        || echo "WARN: CLIP prefetch failed; node will download on first use"
      "$HF_BIN" download Qwen/Qwen3-8B-GGUF Qwen3-8B-Q4_K_M.gguf \
        --local-dir "$COMFYUI_PATH/models/HY-Motion/ckpts/GGUF/" \
        || echo "WARN: Qwen3 GGUF prefetch failed; use the transformers LLM loader instead"
      echo "Pre-fetching Text2MotionPrompter into HF cache..."
      "$HF_BIN" download Text2MotionPrompter/Text2MotionPrompter \
        || echo "WARN: Text2MotionPrompter prefetch failed; node will download on first use"
      echo "Pre-fetching UniRig checkpoints into HF cache..."
      "$HF_BIN" download VAST-AI/UniRig \
        --include "skeleton/*" "skin/*" \
        || echo "WARN: UniRig ckpt prefetch failed; Load Model node will download on first use"
    else
      echo "WARN: no hf/huggingface-cli CLI found (venv bin or PATH); skipping motion weight prefetch"
    fi
  fi
fi

# Stamp the arch AFTER installs so a failed install retries on next boot.
[ -n "$COMPUTE_CAP" ] && echo "$COMPUTE_CAP" > "$ARCH_STAMP"

echo "=== Setup complete ($(date -u +%FT%TZ), $((SECONDS - BOOT_SECONDS))s since boot start); starting ComfyUI via RunPod /start-runpod.sh ==="
exec /start-runpod.sh
