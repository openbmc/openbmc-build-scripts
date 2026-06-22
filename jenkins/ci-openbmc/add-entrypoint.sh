#!/bin/bash
# add-entrypoint.sh - Layer the gosu entrypoint onto a raw sstate image
# and produce the final generic container tag.
#
# Required environment variables:
#   CONTAINER_TAG - the raw sstate image to build FROM
#   GENERIC_TAG   - the final output image tag
#   SCRIPT_DIR    - directory containing entrypoint.sh and this script

set -e

BUILD_DIR=$(mktemp -d)
trap 'rm -rf '"${BUILD_DIR}" EXIT

cp "${SCRIPT_DIR}/entrypoint.sh" "${BUILD_DIR}/entrypoint.sh"
chmod +x "${BUILD_DIR}/entrypoint.sh"

cat > "${BUILD_DIR}/Dockerfile" << EOF
FROM ${CONTAINER_TAG}
USER root
RUN apt-get update && \\
    apt-get install -y --no-install-recommends gosu && \\
    rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
EOF

docker build --network=host -t "${GENERIC_TAG}" "${BUILD_DIR}"
