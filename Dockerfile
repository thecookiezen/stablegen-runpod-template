# syntax=docker/dockerfile:1
#
# StableGen backend for RunPod.
#
# ComfyUI (from RunPod's official image) + StableGen's custom nodes, pre-cloned.
# Everything GPU-specific (CUDA extension builds) and all model downloads are
# deliberately LEFT OUT of the image: they happen at first pod boot via the
# entrypoint script (start.sh, installed as /start.sh), because docker builds
# have no GPU and /workspace (the network volume) only exists on the pod.
#
# Build locally (no GPU needed) and push to your registry:
#   ./build_and_push.sh <your-registry>/stablegen-comfyui:latest
#
# Overrides (all optional):
#   BASE_TAG        runpod/comfyui tag to build from. Keep the cuda12.8 line:
#                   the boot script's venv detection and hub<2.0 heal are
#                   tuned for it.
#   STABLEGEN_REF   commit/tag of sakalond/StableGen that provides installer.py
#                   (node clones + compat patches + model manifest).
#   *_REF           pin a specific commit of a custom node repo. Empty means
#                   "whatever the repo's default branch is at build time"; the
#                   resolved SHAs are recorded in BUILD_INFO for debugging.

ARG BASE_TAG=1.4.0-comfyuiv0.35.0-cuda12.8
FROM runpod/comfyui:${BASE_TAG}

# Re-declare so the tag is recorded in BUILD_INFO (ARGs before FROM don't
# flow into the build stage unless re-declared).
ARG BASE_TAG

ARG STABLEGEN_REF=1d6e83fc966afc8b2c196c011b75ce7cdaa07c83
ARG TRELLIS2_REF=
ARG IPADAPTER_REF=
ARG GGUF_REF=
ARG MARIGOLD_REF=
ARG STABLEDELIGHT_REF=

ENV DEBIAN_FRONTEND=noninteractive

# Fail the build early if RunPod changes the baked layout in a future tag.
RUN test -f /opt/comfyui-baked/main.py || { \
      echo "ERROR: /opt/comfyui-baked/main.py not found in runpod/comfyui:${BASE_TAG}." >&2; \
      echo "       The image layout changed; update BASE_TAG and the paths in start.sh." >&2; \
      exit 1; \
    }

# Small system deps the boot script assumes (most are already in the base image).
RUN apt-get update \
 && apt-get install -y --no-install-recommends wget ca-certificates git \
 && rm -rf /var/lib/apt/lists/*

# StableGen repo. Only installer.py matters at boot: the headless driver
# (/opt/stablegen-template/stablegen_install.py) imports it and reuses its
# clone/patch/install/download logic instead of duplicating it.
RUN git clone https://github.com/sakalond/StableGen.git /opt/stablegen \
 && git -C /opt/stablegen checkout "${STABLEGEN_REF}" \
 && rm -rf /opt/stablegen/.git

# Custom nodes, pre-cloned into the baked ComfyUI copy. The boot script copies
# this tree to /workspace on first boot, and the StableGen installer driver
# then applies its compat patches, pip deps and install.py steps on top.
# .git dirs are kept so ComfyUI-Manager can still update nodes later.
RUN set -eux; \
    baked=/opt/comfyui-baked/custom_nodes; \
    mkdir -p "$baked"; \
    clone() { \
      name="$1"; url="$2"; ref="$3"; \
      if [ -n "$ref" ]; then \
        git clone "$url" "$baked/$name" \
          && git -C "$baked/$name" checkout "$ref"; \
      else \
        git clone --depth 1 "$url" "$baked/$name"; \
      fi; \
    }; \
    clone ComfyUI_IPAdapter_plus   https://github.com/cubiq/ComfyUI_IPAdapter_plus.git      "${IPADAPTER_REF}"; \
    clone ComfyUI-GGUF             https://github.com/city96/ComfyUI-GGUF.git              "${GGUF_REF}"; \
    clone ComfyUI-TRELLIS2         https://github.com/PozzettiAndrea/ComfyUI-TRELLIS2.git  "${TRELLIS2_REF}"; \
    clone ComfyUI-Marigold         https://github.com/kijai/ComfyUI-Marigold.git            "${MARIGOLD_REF}"; \
    clone ComfyUI_StableDelight_ll https://github.com/lldacing/ComfyUI_StableDelight_ll.git "${STABLEDELIGHT_REF}"

# Take over the container entrypoint. The base image uses
# ENTRYPOINT ["/start.sh"], so a RunPod template "start command" would only
# become an ignored argument to it (this is why cmd-override setups silently
# do nothing on this image). Instead we rename RunPod's script and install
# ours as /start.sh: the StableGen setup runs on every container start, then
# hands off to the original. The RunPod template needs NO start command.
RUN mv /start.sh /start-runpod.sh
COPY start.sh /start.sh
COPY stablegen_install.py /opt/stablegen-template/stablegen_install.py
RUN chmod +x /start.sh /opt/stablegen-template/stablegen_install.py

# Record what went into this image (base tag + exact node commits).
RUN { \
      echo "base_image: runpod/comfyui:${BASE_TAG}"; \
      echo "stablegen: ${STABLEGEN_REF}"; \
      echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
      for d in /opt/comfyui-baked/custom_nodes/*; do \
        [ -d "$d" ] || continue; \
        echo "node $(basename "$d"): $(git -C "$d" rev-parse HEAD 2>/dev/null || echo unknown)"; \
      done; \
    } > /opt/stablegen-template/BUILD_INFO \
 && cat /opt/stablegen-template/BUILD_INFO

# Match the boot script's persistent paths in manual shells (SSH / Jupyter).
ENV COMFY_ENV_ROOT=/workspace/.ce \
    HF_HOME=/workspace/.cache/huggingface
