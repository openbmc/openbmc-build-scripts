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
#   EXTRA_DOCKER_RUN_ARGS:  Optional, pass arguments to docker run
#   EXTRA_UNIT_TEST_ARGS:  Optional, pass arguments to unit-test.py
#   INTERACTIVE: Optional, run a bash shell instead of unit-test.py
#   http_proxy: Optional, run the container with proxy environment

# Trace bash processing. Set -e so when a step fails, we fail the build
set -uo pipefail

# Default variables
BRANCH=${BRANCH:-"master"}
DOCKER_WORKDIR="${DOCKER_WORKDIR:-$WORKSPACE}"
OBMC_BUILD_SCRIPTS="openbmc-build-scripts"
UNIT_TEST_SCRIPT_DIR="${DOCKER_WORKDIR}/${OBMC_BUILD_SCRIPTS}/scripts"
UNIT_TEST_PY="unit-test.py"
DBUS_UNIT_TEST_PY="dbus-unit-test.py"
TEST_ONLY="${TEST_ONLY:-}"
DBUS_SYS_CONFIG_FILE=${dbus_sys_config_file:-"/usr/share/dbus-1/system.conf"}
MAKEFLAGS="${MAKEFLAGS:-""}"
NO_FORMAT_CODE="${NO_FORMAT_CODE:-}"
INTERACTIVE="${INTERACTIVE:-}"
http_proxy=${http_proxy:-}

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
    UNIT_TEST="${UNIT_TEST_SCRIPT_DIR}/${UNIT_TEST_PY},-w,${DOCKER_WORKDIR},\
-p,${UNIT_TEST_PKG},-b,$BRANCH,-v${TEST_ONLY:+,-t}${NO_FORMAT_CODE:+,-n}\
${EXTRA_UNIT_TEST_ARGS}"
fi

# Run the docker unit test container with the unit test execution script
echo "Executing docker image"

PROXY_ENV=""
# Set up proxies
if [ -n "${http_proxy}" ]; then
    PROXY_ENV=" \
        --env HTTP_PROXY=${http_proxy} \
        --env HTTPS_PROXY=${http_proxy} \
        --env FTP_PROXY=${http_proxy} \
        --env http_proxy=${http_proxy} \
        --env https_proxy=${http_proxy} \
        --env ftp_proxy=${http_proxy}"
fi

# If we are building on a podman based machine, need to have this set in
# the env to allow the home mount to work (no impact on non-podman systems)
export PODMAN_USERNS="keep-id"

# shellcheck disable=SC2086 # ${PROXY_ENV} and ${EXTRA_DOCKER_RUN_ARGS} are
# meant to be split
docker run --cap-add=sys_admin --rm=true \
    --privileged=true \
    ${PROXY_ENV} \
    -u "$USER" \
    -w "${DOCKER_WORKDIR}" -v "${WORKSPACE}":"${DOCKER_WORKDIR}" \
    -e "MAKEFLAGS=${MAKEFLAGS}" \
    ${EXTRA_DOCKER_RUN_ARGS:-} \
    -${INTERACTIVE:+i}t "${DOCKER_IMG_NAME}" \
    "${UNIT_TEST_SCRIPT_DIR}/${DBUS_UNIT_TEST_PY}" -u "${UNIT_TEST}" \
    -f "${DBUS_SYS_CONFIG_FILE}"

# Timestamp for build
echo "Unit test build completed, $(date)"
