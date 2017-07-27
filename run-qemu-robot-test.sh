#!/bin/bash -xe

# This script is for starting QEMU against the input build and running
#  the robot CI test suite against it.
#

#
#  Parameters:
#   UPSTREAM_WORKSPACE = <required, base dir of QEMU image>
#   WORKSPACE =          <optional, temp dir for robot script>

set -uo pipefail

QEMU_RUN_TIMER=${QEMU_RUN_TIMER:-300}
WORKSPACE=${WORKSPACE:-${HOME}/qemu-launch}
DOCKER_IMG_NAME=${DOCKER_IMG_NAME:-openbmc/ubuntu-robot-qemu}
OBMC_BUILD_DIR=${OBMC_BUILD_DIR:-/tmp/openbmc/build}
UPSTREAM_WORKSPACE=${UPSTREAM_WORKSPACE:-/home/alanny/buildopenbmc/build}

# Determine the architecture
ARCH=$(uname -m)

# Determine the prefix of the Dockerfile's base image and the QEMU_ARCH variable
case ${ARCH} in
  "ppc64le")
    DOCKER_BASE="ppc64le/"
    QEMU_ARCH="ppc64le-linux"
    ;;
  "x86_64")
    DOCKER_BASE=""
    QEMU_ARCH="x86_64-linux"
    ;;
  *)
    echo "Unsupported system architecture(${ARCH}) found for docker image"
    exit 1
esac

# Get base directory openbmc-scripts-repo so we can return later
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

cp $DIR/scripts/* ${UPSTREAM_WORKSPACE}

# Move into the Upstream Workspace Directory
cd ${UPSTREAM_WORKSPACE}

# Create the base docker image for qemu
. "$DIR/scripts/build-qemu-robot-docker.sh" "$DOCKER_IMG_NAME"

# Start QEMU docker instance
# root in docker required to open up the https/ssh ports
obmc_qemu_docker=$(docker run --detach \
                              --user root \
                              --env HOME=${OBMC_BUILD_DIR} \
                              --env QEMU_RUN_TIMER=${QEMU_RUN_TIMER} \
                              --env QEMU_ARCH=${QEMU_ARCH} \
                              --workdir "${OBMC_BUILD_DIR}"           \
                              --volume "${UPSTREAM_WORKSPACE}":"${OBMC_BUILD_DIR}" \
                              --tty \
                              ${DOCKER_IMG_NAME} ${OBMC_BUILD_DIR}/boot-qemu-test.exp)


DOCKER_SSH_PORT=22
DOCKER_HTTPS_PORT=443
DOCKER_QEMU_IP_ADDR="$(docker inspect $obmc_qemu_docker |  \
                      grep -m 1 "IPAddress\":" | cut -d '"' -f 4)"

# Now wait for the openbmc qemu docker instance to get to standby
attempt=60
while [ $attempt -gt 0 ]; do
    attempt=$(( $attempt - 1 ))
    echo "Waiting for qemu to get to standby (attempt: $attempt)..."
    result=$(docker logs $obmc_qemu_docker)
    if grep -q 'OPENBMC-READY' <<< $result ; then
        echo "QEMU is ready!"
        # Give QEMU a few secs to stablize
        sleep 5
        break
    fi
    sleep 2
done

if [ "$attempt" -eq 0 ]; then
    echo "Timed out waiting for QEMU, exiting"
    exit 1
fi

# Now run the robot test

# Timestamp for job
echo "Robot Test started, $(date)"

mkdir -p ${WORKSPACE}
cd ${WORKSPACE}

# Copy in the script which will execute the robot tests
cp $DIR/scripts/run-robot.sh ${WORKSPACE}

# Run the docker container to execute the robot test cases
# The test results will be put in ${WORKSPACE}
docker run --rm \
           --user root \
           --env HOME=${HOME} \
           --env IP_ADDR=${DOCKER_QEMU_IP_ADDR} \
           --env SSH_PORT=${DOCKER_SSH_PORT} \
           --env HTTPS_PORT=${DOCKER_HTTPS_PORT} \
           --workdir ${HOME} \
           --volume ${WORKSPACE}:${HOME} \
           --tty \
           ${DOCKER_IMG_NAME} ${HOME}/run-robot.sh

# Now stop the QEMU docker image
docker stop $obmc_qemu_docker
