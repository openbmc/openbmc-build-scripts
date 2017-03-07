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
DBUS_DIR="/tmp/dbus"
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

# Copy dbus config file to dbus dir and modify
cp ${DBUS_SYS_CONFIG_FILE} ${DBUS_DIR}/system-local.conf
sed -i 's/<type>system<\/type>/<type>session<\/type>/' ${DBUS_DIR}/system-local.conf
sed -i 's/<pidfile>.*<\/pidfile>/<pidfile>\/tmp\/dbus\/pid<\/pidfile>/' ${DBUS_DIR}/system-local.conf
sed -i 's/<listen>.*<\/listen>/<listen>unix:path=\/tmp\/dbus\/system_bus_socket<\/listen>/'  ${DBUS_DIR}/system-local.conf
sed -i 's/<deny/<allow/g' ${DBUS_DIR}/system-local.conf
if [ ! -d "${DBUS_DIR}" ]; then
    mkdir "${DBUS_DIR}" 
fi

# Launch dbus
if [ -f "${DBUS_DIR}/pid" ]; then
    kill `cat ${DBUS_DIR}/pid`
fi
DBUS_ADDR=`/usr/bin/dbus-launch --config-file="${DBUS_DIR}/system-local.conf" | grep "DBUS_SESSION_BUS_ADDRESS" | sed 's/DBUS_SESSION_BUS_ADDRESS\=//'`

# Configure docker build
cd ${WORKSPACE}/${OBMC_BUILD_SCRIPTS}
echo "Building docker image with build-unit-test-docker.sh"
./build-unit-test-docker.sh ${DOCKER_IMG_NAME} ${DISTRO}

# Run the docker unit test container with the unit test execution script
echo "Executing docker image"
docker run --cap-add=sys_admin --rm=true \
    --privileged=true \
    -v ${DBUS_DIR}:${DBUS_DIR} \
    -e DBUS_SESSION_BUS_ADDRESS=${DBUS_ADDR} \
    -e DBUS_STARTER_BUS_TYPE=session \
    -w "${WORKSPACE}" -v "${WORKSPACE}":"${WORKSPACE}" \
    -t ${DOCKER_IMG_NAME} \
    ${WORKSPACE}/${UNIT_TEST_PY} -w ${WORKSPACE} -p ${UNIT_TEST_PKG} -v

# Timestamp for build
echo "Unit test build completed, $(date)"
