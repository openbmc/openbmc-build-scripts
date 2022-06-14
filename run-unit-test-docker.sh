#!/bin/bash -xe

# This build script is for running the Jenkins unit test builds using docker.
#
# This script will build a docker container which will then be used to build
# and test the input UNIT_TEST_PKG. The docker container will be pre-populated
# with the most used OpenBMC repositories (phosphor-dbus-interfaces, sdbusplus,
# phosphor-logging, ...). This allows the use of docker caching
# capabilities so the dependent repositories are only built once per update
# to their corresponding repository. If a BRANCH parameter is input then the
# docker container will be pre-populated with the latest code from that input
# branch. If the branch does not exist in the repository, then master will be
# used.
#
#   UNIT_TEST_PKG:   Required, repository which has been extracted and is to
#                    be tested
#   WORKSPACE:       Required, location of unit test scripts and repository
#                    code to test
#   BRANCH:          Optional, branch to build from each of the
#                    openbmc repositories. default is master, which will be
#                    used if input branch not provided or not found
#   dbus_sys_config_file: Optional, with the default being
#                         `/usr/share/dbus-1/system.conf`
#   TEST_ONLY:       Optional, do not run analysis tools
#   NO_FORMAT_CODE:  Optional, do not run format-code.sh
#   EXTRA_UNIT_TEST_ARGS:  Optional, pass arguments to unit-test.py
#   INTERACTIVE: Optional, run a bash shell instead of unit-test.py

# Trace bash processing. Set -e so when a step fails, we fail the build
set -uo pipefail

# Default variables
BRANCH=${BRANCH:-"master"}
OBMC_BUILD_SCRIPTS="openbmc-build-scripts"
UNIT_TEST_PY_DIR="scripts"
CONFIG_DIR="config"
UNIT_TEST_PY="unit-test.py"
FORMAT_CODE_SH="format-code.sh"
SPELLINGS_TXT="openbmc-spelling.txt"
ESLINT_CONFIG="eslint-global-config.json"
DBUS_UNIT_TEST_PY="dbus-unit-test.py"
TEST_ONLY="${TEST_ONLY:-}"
DBUS_SYS_CONFIG_FILE=${dbus_sys_config_file:-"/usr/share/dbus-1/system.conf"}
MAKEFLAGS="${MAKEFLAGS:-""}"
DOCKER_WORKDIR="${DOCKER_WORKDIR:-$WORKSPACE}"
NO_FORMAT_CODE="${NO_FORMAT_CODE:-}"
INTERACTIVE="${INTERACTIVE:-}"

# Timestamp for job
echo "Unit test build started, $(date)"

# Check workspace, build scripts, and package to be unit tested exists
if [ ! -d "${WORKSPACE}" ]; then
    echo "Workspace(${WORKSPACE}) doesn't exist, exiting..."
    exit 1
fi
if [ ! -d "${WORKSPACE}/${OBMC_BUILD_SCRIPTS}" ]; then
    echo "Package(${OBMC_BUILD_SCRIPTS}) not found in ${WORKSPACE}, exiting..."
    exit 1
fi
# shellcheck disable=SC2153 # UNIT_TEST_PKG is not misspelled.
if [ ! -d "${WORKSPACE}/${UNIT_TEST_PKG}" ]; then
    echo "Package(${UNIT_TEST_PKG}) not found in ${WORKSPACE}, exiting..."
    exit 1
fi

# Copy unit test script into workspace
cp "${WORKSPACE}"/${OBMC_BUILD_SCRIPTS}/${UNIT_TEST_PY_DIR}/${UNIT_TEST_PY} \
"${WORKSPACE}"/${UNIT_TEST_PY}
chmod a+x "${WORKSPACE}"/${UNIT_TEST_PY}

# Copy dbus unit test script into workspace
cp "${WORKSPACE}"/${OBMC_BUILD_SCRIPTS}/${UNIT_TEST_PY_DIR}/${DBUS_UNIT_TEST_PY} \
"${WORKSPACE}"/${DBUS_UNIT_TEST_PY}
chmod a+x "${WORKSPACE}"/${DBUS_UNIT_TEST_PY}

# Copy format code script into workspace
cp "${WORKSPACE}"/${OBMC_BUILD_SCRIPTS}/${UNIT_TEST_PY_DIR}/${FORMAT_CODE_SH} \
"${WORKSPACE}"/${FORMAT_CODE_SH}
chmod a+x "${WORKSPACE}"/${FORMAT_CODE_SH}

# Copy spellings.txt file into workspace
cp "${WORKSPACE}"/${OBMC_BUILD_SCRIPTS}/${CONFIG_DIR}/${SPELLINGS_TXT} \
"${WORKSPACE}"/${SPELLINGS_TXT}

# Copy the eslintconfig file into workspce
cp "${WORKSPACE}"/${OBMC_BUILD_SCRIPTS}/${CONFIG_DIR}/${ESLINT_CONFIG} \
"${WORKSPACE}"/${ESLINT_CONFIG}

# Configure docker build
cd "${WORKSPACE}"/${OBMC_BUILD_SCRIPTS}
echo "Building docker image with build-unit-test-docker"
# Export input env variables
export BRANCH
DOCKER_IMG_NAME=$(./scripts/build-unit-test-docker)
export DOCKER_IMG_NAME

# Allow the user to pass options through to unit-test.py:
#   EXTRA_UNIT_TEST_ARGS="-r 100" ...
EXTRA_UNIT_TEST_ARGS="${EXTRA_UNIT_TEST_ARGS:+,${EXTRA_UNIT_TEST_ARGS/ /,}}"

# Unit test and parameters
if [ "${INTERACTIVE}" ]; then
    UNIT_TEST="/bin/bash"
else
    UNIT_TEST="${DOCKER_WORKDIR}/${UNIT_TEST_PY},-w,${DOCKER_WORKDIR},\
-p,${UNIT_TEST_PKG},-b,$BRANCH,-v${TEST_ONLY:+,-t}${NO_FORMAT_CODE:+,-n}\
${EXTRA_UNIT_TEST_ARGS}"
fi

# Run the docker unit test container with the unit test execution script
echo "Executing docker image"
docker run --cap-add=sys_admin --rm=true \
    --privileged=true \
    -u "$USER" \
    -w "${DOCKER_WORKDIR}" -v "${WORKSPACE}":"${DOCKER_WORKDIR}" \
    -e "MAKEFLAGS=${MAKEFLAGS}" \
    -${INTERACTIVE:+i}t "${DOCKER_IMG_NAME}" \
    "${DOCKER_WORKDIR}"/${DBUS_UNIT_TEST_PY} -u "${UNIT_TEST}" \
    -f "${DBUS_SYS_CONFIG_FILE}"

# Timestamp for build
echo "Unit test build completed, $(date)"

# Clean up copied scripts.
rm "${WORKSPACE}"/${UNIT_TEST_PY}
rm "${WORKSPACE}"/${DBUS_UNIT_TEST_PY}
rm "${WORKSPACE}"/${FORMAT_CODE_SH}
rm "${WORKSPACE}"/${ESLINT_CONFIG}

