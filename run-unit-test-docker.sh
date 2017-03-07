#!/bin/bash -xe

# This build script is for running the Jenkins unit test builds using docker.
#
# It uses a few variables which are part of Jenkins build job matrix:
#   distro = fedora|ubuntu|ubuntu:14.04|ubuntu:16.04
#   dbus_sys_config_file = <path of the dbus config file>
#   WORKSPACE = <location of unit test execution script>

# Trace bash processing. Set -e so when a step fails, we fail the build
set -uo pipefail

# Default variables
DOCKER_IMG_NAME="openbmc/ubuntu-unit-test"
DISTRO=${distro:-ubuntu:latest}
WORKSPACE=${WORKSPACE:-${TMP}/unit-test${RANDOM}}
OBMC_BUILD_SCRIPTS="openbmc-build-scripts"
UNIT_TEST_PY_DIR="scripts"
UNIT_TEST_PY="unit-test.py"
DBUS_UNIT_TEST_PY="dbus-unit-test.py"
DBUS_DIR=`mktemp -d`
DBUS_SYS_CONFIG_FILE=${dbus_sys_config_file:-"/usr/share/dbus-1/system.conf"}

# Timestamp for job
echo "Unit test build started, $(date)"

# Currently only support ubuntu:latest due to systemd requirements
if [[ "${DISTRO}" == "ubuntu"* ]]; then
    DISTRO="ubuntu:latest"
elif [[ "${DISTRO}" == "fedora" ]]; then
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

# Configure docker build
cd ${WORKSPACE}/${OBMC_BUILD_SCRIPTS}
echo "Building docker image with build-unit-test-docker.sh"
./build-unit-test-docker.sh ${DOCKER_IMG_NAME} ${DISTRO}

# Run the docker unit test container with the unit test execution script
echo "Executing docker image"
docker run --cap-add=sys_admin --rm=true \
    --privileged=true \
    -v ${DBUS_DIR} \
    -w "${WORKSPACE}" -v "${WORKSPACE}":"${WORKSPACE}" \
    -t ${DOCKER_IMG_NAME} \
    ${WORKSPACE}/${DBUS_UNIT_TEST_PY} -u ${WORKSPACE}/${UNIT_TEST_PY} \
    -w ${WORKSPACE} -p ${UNIT_TEST_PKG} -v -t ${DBUS_DIR} \
    -f ${DBUS_SYS_CONFIG_FILE}

# Timestamp for build
echo "Unit test build completed, $(date)"
