#!/bin/bash -xe

# This build script is for running the Jenkins unit test builds using docker.
#
# It uses a few variables which are part of Jenkins build job matrix:
#   distro = fedora|ubuntu|ubuntu:14.04|ubuntu:16.04
#   WORKSPACE = <location of unit test execution script>

# Trace bash processing. Set -e so when a step fails, we fail the build
set -uo pipefail

# Default variables
DISTRO=${distro:-ubuntu}
WORKSPACE=${WORKSPACE:-${HOME}/unit-test${RANDOM}}
UNIT_TEST_SH="unit-test.sh"

# Timestamp for job
echo "Unit test build started, $(date)"

# Currently only support ubuntu:latest due to systemd requirements
if [[ "${DISTRO}" == "ubuntu"* ]]; then
    DISTRO="ubuntu:latest"
elif [[ "${DISTRO}" == "fedora" ]]; then
    echo "Distro (${DISTRO}) not supported, running as ubuntu"
    DISTRO="ubuntu:latest"
fi

# Check workspace exists, create if not
if [ ! -d "${WORKSPACE}" ]; then
    echo "${WORKSPACE} doesn't exist, creating..."
    mkdir "${WORKSPACE}"
fi

# Copy unit test script into workspace
cp scripts/${UNIT_TEST_SH} ${WORKSPACE}/${UNIT_TEST_SH}
chmod a+x ${WORKSPACE}/${UNIT_TEST_SH}

# Configure docker build
echo "Building docker image with build-unit-test-docker.sh"
./build-unit-test-docker.sh openbmc/${DISTRO} ${DISTRO}

# Run the docker unit test container with the unit test execution script
echo "Executing docker image"
docker run --cap-add=sys_admin --rm=true \
    -e WORKSPACE=${WORKSPACE}/phosphor-event \
    -w "${HOME}" -v "${HOME}":"${HOME}" \
    -t openbmc/${DISTRO} ${WORKSPACE}/${UNIT_TEST_SH}

# Timestamp for build
echo "Unit test build completed, $(date)"

