#!/bin/bash
# create-container.sh - Bake a finished BitBake sstate cache into a Docker image.
#
# Required environment variables:
#   TARGET_IMAGE  - base build container image (e.g. openbmc/ubuntu:24.04-p10bmc-master-aarch64)
#   BUILD_BASE    - path to the openbmc checkout that was built (BUILD_BASE/build/TARGET/...)
#   TARGET        - MACHINE name (e.g. p10bmc)
#   CONTAINER_TAG - destination tag for the raw sstate image

set -e

BUILD_DIR=$(mktemp -d)
trap 'rm -rf '"${BUILD_DIR}" EXIT

# Clean up heavy build artifacts that should not end up in the image
rm -rf "${BUILD_BASE}/build/${TARGET}/tmp"
rm -rf "${BUILD_BASE}/build/${TARGET}/downloads"

cp -r "${BUILD_BASE}/build/${TARGET}/sstate-cache" "${BUILD_DIR}/sstate-cache"

cat > "${BUILD_DIR}/Dockerfile" << EOF
FROM ${TARGET_IMAGE}
COPY sstate-cache/ /var/lib/openbmc/sstate-cache/
EOF

docker build --no-cache -t "${CONTAINER_TAG}" "${BUILD_DIR}"
