#!/usr/bin/env bash
# Build and push the StableGen ComfyUI image for RunPod.
#
# Usage:
#   ./build_and_push.sh <registry-repo>[:tag]
#
# Examples:
#   ./build_and_push.sh docker.io/myuser/stablegen-comfyui:latest
#   ./build_and_push.sh ghcr.io/myuser/stablegen-comfyui:0.1.0
#
# Build-arg overrides (see Dockerfile for the full list):
#   BASE_TAG=1.4.1-rc.175-comfyuiv0.35.0-cuda12.8 ./build_and_push.sh ...
#   STABLEGEN_REF=<commit>                        ./build_and_push.sh ...
#   TRELLIS2_REF=<commit>                         ./build_and_push.sh ...
#
# You need push access to the registry (docker login / gh auth) and roughly
# 15 GB of free disk. No GPU is required to build.

set -euo pipefail

IMAGE="${1:?usage: ./build_and_push.sh <registry-repo>[:tag]}"
cd "$(dirname "$0")"

BASE_TAG="${BASE_TAG:-1.4.0-comfyuiv0.35.0-cuda12.8}"
STABLEGEN_REF="${STABLEGEN_REF:-1d6e83fc966afc8b2c196c011b75ce7cdaa07c83}"

echo "Building ${IMAGE}"
echo "  BASE_TAG=${BASE_TAG}"
echo "  STABLEGEN_REF=${STABLEGEN_REF}"

docker buildx build \
  --platform linux/amd64 \
  --build-arg BASE_TAG="${BASE_TAG}" \
  --build-arg STABLEGEN_REF="${STABLEGEN_REF}" \
  ${TRELLIS2_REF:+--build-arg TRELLIS2_REF="${TRELLIS2_REF}"} \
  ${IPADAPTER_REF:+--build-arg IPADAPTER_REF="${IPADAPTER_REF}"} \
  ${GGUF_REF:+--build-arg GGUF_REF="${GGUF_REF}"} \
  ${MARIGOLD_REF:+--build-arg MARIGOLD_REF="${MARIGOLD_REF}"} \
  ${STABLEDELIGHT_REF:+--build-arg STABLEDELIGHT_REF="${STABLEDELIGHT_REF}"} \
  -t "${IMAGE}" \
  --push \
  .

cat <<EOF

Done. Next steps on runpod.io:
  1. Save & New Template -> Container Image: ${IMAGE}
  2. Start Command: leave EMPTY (the image's entrypoint runs the StableGen setup)
  3. Attach a network volume (>= 100 GB recommended) at /workspace
  4. Expose HTTP ports 8188 (ComfyUI), 8888 (JupyterLab), 8080 (FileBrowser)

The image prints the exact node commits it baked into /opt/stablegen-template/BUILD_INFO.
EOF
