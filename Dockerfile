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
#   COMFYUI_VERSION ComfyUI release baked INSTEAD of the base image's core.
#                   RunPod's images lag upstream releases; the swap keeps the
#                   image's locked torch stack but runs current ComfyUI. The
#                   build fails if the base image already ships this version
#                   or newer (then drop the override).
#   *_REF           pinned commit of a custom node repo. The defaults are the
#                   newest commits verified to work with StableGen's installer
#                   (see README); the resolved SHAs are recorded in BUILD_INFO.

ARG BASE_TAG=1.5.0-rc.181-comfyuiv0.35.0-cuda12.8
FROM runpod/comfyui:${BASE_TAG}

# Re-declare so the tag is recorded in BUILD_INFO (ARGs before FROM don't
# flow into the build stage unless re-declared).
ARG BASE_TAG
ARG COMFYUI_VERSION=v0.41.1

ARG STABLEGEN_REF=1d6e83fc966afc8b2c196c011b75ce7cdaa07c83
ARG TRELLIS2_REF=3e696f2cf174dba141c9efce0205e9a2d87e908a
ARG IPADAPTER_REF=a0f451a5113cf9becb0847b92884cb10cbdec0ef
ARG GGUF_REF=6ea2651e7df66d7585f6ffee804b20e92fb38b8a
ARG MARIGOLD_REF=2adfec75c430b0751a98a82453dc2dd8077bca85
ARG STABLEDELIGHT_REF=42c0463cc65554509804cbf577a1675c61499ec4

# Motion add-on (text-to-animation + auto-rigging; installed by start.sh, not
# StableGen's installer). Same *_REF override mechanics as the nodes above.
ARG HYMOTION_REF=60843a4d631efa3989b5c512ae547f996c30dcc3
ARG UNIRIG_REF=69ee59dc459d2da7cb0291930c1f944886c31d7c

ENV DEBIAN_FRONTEND=noninteractive

# Fail the build early if RunPod changes the baked layout in a future tag.
RUN test -f /opt/comfyui-baked/main.py || { \
      echo "ERROR: /opt/comfyui-baked/main.py not found in runpod/comfyui:${BASE_TAG}." >&2; \
      echo "       The image layout changed; update BASE_TAG and the paths in start.sh." >&2; \
      exit 1; \
    }

# --- ComfyUI core override ----------------------------------------------------
# Swap the base image's (older) ComfyUI core for a pinned upstream release,
# keeping what the base image adds around it:
#   * custom_nodes/{ComfyUI-KJNodes, Civicomfy, ComfyUI-RunpodDirect}
#     (ComfyUI-Manager is NOT a baked node in newer base images: it ships as
#     the comfyui_manager pip package, loaded by core via --enable-manager)
#   * user/__manager (pre-baked ComfyUI-Manager cache/config)
#   * the git repo (re-created + tagged so Manager reports the real version)
# The torch stack is NOT touched: the new core's requirements install against
# /opt/comfyui-runtime-constraints.txt, so torch/torchvision/torchaudio stay
# at the image's CUDA-matched pins. Only pure-Python packages (frontend,
# workflow templates, embedded docs, comfy-kitchen, comfy-aimdo) move; the
# comfyui_manager pip package version is checked against the new core's
# manager_requirements.txt pin by the base start script on every boot.
# The manifest line we append makes the base start script's
# upgrade_comfyui_if_needed() rsync this core over an existing /workspace
# install on the next pod boot (models, user data and custom nodes excluded).
RUN set -eux; \
    baked_comfyui="$(sed -n 's/^COMFYUI_VERSION=//p' /opt/comfyui-baked/.runpod-bundle-version)"; \
    if printf '%s\n%s\n' "${COMFYUI_VERSION#v}" "${baked_comfyui#v}" | sort -V | head -1 | grep -qx "${COMFYUI_VERSION#v}"; then \
      echo "ERROR: base image already ships ComfyUI ${baked_comfyui} >= override ${COMFYUI_VERSION}." >&2; \
      echo "       Drop the COMFYUI_VERSION override (or bump it) and rebuild." >&2; \
      exit 1; \
    fi; \
    curl -fSL "https://github.com/comfyanonymous/ComfyUI/archive/refs/tags/${COMFYUI_VERSION}.tar.gz" \
      -o /tmp/comfyui-core.tar.gz; \
    mkdir -p /tmp/comfyui-core; \
    tar xzf /tmp/comfyui-core.tar.gz --strip-components=1 -C /tmp/comfyui-core; \
    mkdir -p /tmp/comfyui-core/custom_nodes /tmp/comfyui-core/user; \
    cp -a /opt/comfyui-baked/custom_nodes/. /tmp/comfyui-core/custom_nodes/; \
    cp -a /opt/comfyui-baked/user/. /tmp/comfyui-core/user/; \
    cp -a /opt/comfyui-baked/.runpod-bundle-version /tmp/comfyui-core/.runpod-bundle-version; \
    rm -rf /opt/comfyui-baked; \
    mv /tmp/comfyui-core /opt/comfyui-baked; \
    rm /tmp/comfyui-core.tar.gz; \
    test -f /opt/comfyui-baked/main.py; \
    test -d /opt/comfyui-baked/custom_nodes/ComfyUI-KJNodes; \
    test -d /opt/comfyui-baked/custom_nodes/Civicomfy; \
    test -d /opt/comfyui-baked/custom_nodes/ComfyUI-RunpodDirect; \
    test ! -d /opt/comfyui-baked/custom_nodes/custom_nodes; \
    printf 'STABLEGEN_COMFYUI_OVERRIDE=%s\n' "$COMFYUI_VERSION" >> /opt/comfyui-baked/.runpod-bundle-version; \
    cd /opt/comfyui-baked; \
    rm -rf .git; \
    git init -q; git add -A; \
    git -c user.name=- -c user.email=- commit -q -m "ComfyUI ${COMFYUI_VERSION} (stablegen-runpod-template)"; \
    git tag "${COMFYUI_VERSION}"; \
    git remote add origin https://github.com/comfyanonymous/ComfyUI.git; \
    pip install --constraint /opt/comfyui-runtime-constraints.txt \
      -r /opt/comfyui-baked/requirements.txt

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
#
# The two motion nodes are deliberately baked OUTSIDE this tree (see the
# motion-nodes block below): comfy-env's workspace install discovers EVERY
# custom_nodes/*/comfy-env.toml present at install time, and UniRig ships one.
# Baked into the tree, UniRig's heavy pixi env (bpy/ffmpeg/mesalib conda deps
# + pytorch-lightning/transformers pypi deps) gets dragged into the StableGen
# installer's TRELLIS2 step, making the critical first-boot path longer and
# much harder to attribute. start.sh copies the motion nodes into custom_nodes
# only AFTER the installer driver finished; their envs then build in the
# clearly-labeled, failure-tolerant motion phase.
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

# Motion add-on nodes (same pinning mechanics), staged outside the ComfyUI
# tree. Copied into custom_nodes by start.sh's motion section (after the
# StableGen installer driver), so they never widen the installer's pixi solve.
RUN set -eux; \
    motion=/opt/stablegen-template/motion-nodes; \
    mkdir -p "$motion"; \
    clone() { \
      name="$1"; url="$2"; ref="$3"; \
      if [ -n "$ref" ]; then \
        git clone "$url" "$motion/$name" \
          && git -C "$motion/$name" checkout "$ref"; \
      else \
        git clone --depth 1 "$url" "$motion/$name"; \
      fi; \
    }; \
    clone ComfyUI-HY-Motion1       https://github.com/jtydhr88/ComfyUI-HY-Motion1.git      "${HYMOTION_REF}"; \
    clone ComfyUI-UniRig           https://github.com/PozzettiAndrea/ComfyUI-UniRig.git    "${UNIRIG_REF}"

# Bake the installer driver's own deps into SYSTEM site-packages: comfy-env
# at the pinned schema version the nodes need (derived from the cloned
# TRELLIS2's requirements.txt -- same source of truth as
# stablegen_install.py, which falls back to 0.3.89), plus requests/tqdm.
# The runtime venv is --system-site-packages, so a first boot can run the
# driver (incl. its comfy-env patches) with no PyPI round-trips. The
# driver's pin/heal logic still overrides this if a node ever needs a
# different comfy-env version.
RUN set -eux; \
    pin="$(sed -n 's/^[[:space:]]*comfy-env[[:space:]]*==[[:space:]]*//p' \
      /opt/comfyui-baked/custom_nodes/ComfyUI-TRELLIS2/requirements.txt \
      | head -1 | cut -d' ' -f1)"; \
    pin="${pin:-0.3.89}"; \
    echo "Baking comfy-env==${pin} (from TRELLIS2 requirements.txt) + driver deps"; \
    pip install --no-cache-dir --constraint /opt/comfyui-runtime-constraints.txt \
      "comfy-env==${pin}" requests tqdm

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

# Record what went into this image (base tag + ComfyUI core + exact node commits).
RUN { \
      echo "base_image: runpod/comfyui:${BASE_TAG}"; \
      echo "comfyui_core: ${COMFYUI_VERSION} (upstream release, overrides base image core)"; \
      echo "stablegen: ${STABLEGEN_REF}"; \
      echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
      for d in /opt/comfyui-baked/custom_nodes/* /opt/stablegen-template/motion-nodes/*; do \
        [ -d "$d" ] || continue; \
        echo "node $(basename "$d"): $(git -C "$d" rev-parse HEAD 2>/dev/null || echo unknown)"; \
      done; \
    } > /opt/stablegen-template/BUILD_INFO \
 && cat /opt/stablegen-template/BUILD_INFO

# Canary: RunPod's rc builds sometimes ship a .runpod-bundle-version whose
# managed-node SHAs do not match the commits actually baked (observed on
# 1.5.0-rc.181: BUILD_INFO said 9c2c1726/d3f712f2/a0dccf63 while the manifest
# claimed 555e984b/57105374/9e32b1a0). Their upgrade logic compares the
# manifest against itself, so it stays self-consistent -- but surface the
# divergence at BUILD time so anyone comparing BUILD_INFO with the manifest
# knows the manifest is the stale side. Informational only, never fails.
RUN set -eux; \
    manifest=/opt/comfyui-baked/.runpod-bundle-version; \
    for pair in ComfyUI-KJNodes:KJNODES_SHA Civicomfy:CIVICOMFY_SHA ComfyUI-RunpodDirect:RUNPODDIRECT_SHA; do \
      dir=${pair%%:*}; key=${pair##*:}; \
      want="$(sed -n "s/^${key}=//p" "$manifest" | head -1 | tr -d '[:space:]')"; \
      have="$(git -C "/opt/comfyui-baked/custom_nodes/$dir" rev-parse HEAD 2>/dev/null || true)"; \
      if [ -n "$want" ] && [ -n "$have" ] && [ "${have#"$want"}" = "$have" ]; then \
        echo "NOTE: manifest ${key}=${want} but baked commit is ${have} (RunPod image quirk; informational)." >&2; \
      fi; \
    done

# Match the boot script's persistent paths in manual shells (SSH / Jupyter).
ENV COMFY_ENV_ROOT=/workspace/.ce \
    HF_HOME=/workspace/.cache/huggingface
