#!/bin/bash
# create-container.sh - Commit a finished BitBake build into a Docker image.
#
# Required environment variables:
#   TARGET_IMAGE  - base build container image (e.g. openbmc/ubuntu:24.04-p10bmc-master-aarch64)
#   BUILD_BASE    - path to the openbmc checkout that was built (BUILD_BASE/build/TARGET/...)
#   TARGET        - MACHINE name (e.g. p10bmc)
#   CONTAINER_TAG - destination tag for the raw sstate image
#   LOCAL_TAG     - short local image name used before tagging
#   WORKSPACE     - Jenkins workspace root (mounted into the container for sstate access)

set -e

CONTAINER_ID=$(docker run -d \
    --pids-limit=4000 \
    -u "$(id -u)":"$(id -g)" \
    -v "${WORKSPACE}":"${WORKSPACE}" \
    -w "${WORKSPACE}" \
    "${TARGET_IMAGE}" sleep infinity)

trap 'docker stop '"${CONTAINER_ID}"'; docker rm '"${CONTAINER_ID}" EXIT

docker exec -u root "${CONTAINER_ID}" bash -c "
    rm -rf ${BUILD_BASE}/build/${TARGET}/tmp
    rm -rf ${BUILD_BASE}/build/${TARGET}/downloads
    rm -rf /var/lib/openbmc/sstate-cache
    mkdir -p /var/lib/openbmc/sstate-cache
    cp -r ${BUILD_BASE}/build/${TARGET}/sstate-cache/* \
          /var/lib/openbmc/sstate-cache/
    chmod -R 777 /var/lib/openbmc
"

docker commit "${CONTAINER_ID}" "${LOCAL_TAG}"
docker tag    "${LOCAL_TAG}"    "${CONTAINER_TAG}"

# Disable the trap now that we've committed — normal cleanup path.
trap - EXIT
docker stop "${CONTAINER_ID}"
docker rm   "${CONTAINER_ID}"
