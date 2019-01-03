#!/bin/bash -xe

# This build script is for running the Jenkins unit test builds using docker.
#
#   DISTRO = Docker base image. Ubuntu and Fedora are supported.
#   WORKSPACE = <location of unit test execution script>
#   dbus_sys_config_file = <path of the dbus config file>
#   BRANCH = <optional, branch to build from each of the openbmc/respositories>
#            default is master, which will be used if input branch not
#            provided or not found
#   DOCKER_IMG_NAME = Default is openbmc/ubuntu-unit-test with a -$BRANCH
#            appended if provided

# Trace bash processing. Set -e so when a step fails, we fail the build
set -uo pipefail

# Default variables
DOCKER_IMG_NAME=${DOCKER_IMG_NAME:-"openbmc/ubuntu-unit-test"}
# If branch is defined then append it to docker image name
if [[ -n $BRANCH ]]; then
    DOCKER_IMG_NAME="$DOCKER_IMG_NAME-$BRANCH"
fi
DISTRO=${DISTRO:-ubuntu:bionic}
WORKSPACE=${WORKSPACE:-$(mktemp -d --tmpdir unit-test.XXXXXX)}
OBMC_BUILD_SCRIPTS="openbmc-build-scripts"
UNIT_TEST_PY_DIR="scripts"
UNIT_TEST_PY="unit-test.py"
FORMAT_CODE_SH="format-code.sh"
DBUS_UNIT_TEST_PY="dbus-unit-test.py"
DBUS_SYS_CONFIG_FILE=${dbus_sys_config_file:-"/usr/share/dbus-1/system.conf"}
MAKEFLAGS="${MAKEFLAGS:-""}"

# Timestamp for job
echo "Unit test build started, $(date)"

if [[ "${DISTRO}" == "fedora" ]]; then
    echo "Distro (${DISTRO}) not supported, running as ubuntu"
    DISTRO="ubuntu:latest"
fi

# Check workspace, build scripts, and package to be unit tested exists
if [ ! -d "${WORKSPACE}" ]; then
    echo "Workspace(${WORKSPACE}) doesn't exist, exiting..."
    exit 1
fi
if [ ! -d "${WORKSPACE}/${OBMC_BUILD_SCRIPTS}" ]; then
    echo "Package(${OBMC_BUILD_SCRIPTS}) not found in ${WORKSPACE}, exiting..."
    exit 1
fi
if [ ! -d "${WORKSPACE}/${UNIT_TEST_PKG}" ]; then
    echo "Package(${UNIT_TEST_PKG}) not found in ${WORKSPACE}, exiting..."
    exit 1
fi

# Copy unit test script into workspace
cp ${WORKSPACE}/${OBMC_BUILD_SCRIPTS}/${UNIT_TEST_PY_DIR}/${UNIT_TEST_PY} \
${WORKSPACE}/${UNIT_TEST_PY}
chmod a+x ${WORKSPACE}/${UNIT_TEST_PY}

# Copy dbus unit test script into workspace
cp ${WORKSPACE}/${OBMC_BUILD_SCRIPTS}/${UNIT_TEST_PY_DIR}/${DBUS_UNIT_TEST_PY} \
${WORKSPACE}/${DBUS_UNIT_TEST_PY}
chmod a+x ${WORKSPACE}/${DBUS_UNIT_TEST_PY}

# Copy format code script into workspace
cp ${WORKSPACE}/${OBMC_BUILD_SCRIPTS}/${UNIT_TEST_PY_DIR}/${FORMAT_CODE_SH} \
${WORKSPACE}/${FORMAT_CODE_SH}
chmod a+x ${WORKSPACE}/${FORMAT_CODE_SH}

# Configure docker build
cd ${WORKSPACE}/${OBMC_BUILD_SCRIPTS}
echo "Building docker image with build-unit-test-docker.sh"
./build-unit-test-docker.sh

# Unit test and parameters
UNIT_TEST="${WORKSPACE}/${UNIT_TEST_PY},-w,${WORKSPACE},-p,${UNIT_TEST_PKG},-v"

# Run the docker unit test container with the unit test execution script
echo "Executing docker image"
docker run --cap-add=sys_admin --rm=true \
    --network host \
    --privileged=true \
    -w "${WORKSPACE}" -v "${WORKSPACE}":"${WORKSPACE}" \
    -e "MAKEFLAGS=${MAKEFLAGS}" \
    -t ${DOCKER_IMG_NAME} \
    ${WORKSPACE}/${DBUS_UNIT_TEST_PY} -u ${UNIT_TEST} \
    -f ${DBUS_SYS_CONFIG_FILE}

# Timestamp for build
echo "Unit test build completed, $(date)"
