#!/bin/bash -xe
###############################################################################
#
# This script is for starting QEMU against the input build and running the
# robot CI test suite against it.(ROBOT CI TEST CURRENTLY WIP)
#
###############################################################################
#
# Parameters used by the script:
#  UPSTREAM_WORKSPACE = The directory from which the QEMU components are being
#                       imported from. Generally, this is the build directory
#                       that is generated by the OpenBMC build-setup.sh script
#                       when run with "target=qemu".
#                       Example: /home/builder/workspace/openbmc-build/build.
#
# Optional Variables:
#
#  WORKSPACE          = Path of the workspace directory where some intermediate
#                       files will be saved to.
#  QEMU_RUN_TIMER     = Defaults to 300, a timer for the QEMU container.
#  DOCKER_IMG_NAME    = Defaults to openbmc/ubuntu-robot-qemu, the name the
#                       Docker image will be tagged with when built.
#  OBMC_BUILD_DIR     = Defaults to /tmp/openbmc/build, the path to the
#                       directory where the UPSTREAM_WORKSPACE build files will
#                       be mounted to. Since the build containers have been
#                       changed to use /tmp as the parent directory for their
#                       builds, move the mounting location to be the same to
#                       resolve issues with file links or referrals to exact
#                       paths in the original build directory. If the build
#                       directory was changed in the build-setup.sh run, this
#                       variable should also be changed. Otherwise, the default
#                       should be used.
#  LAUNCH             = Used to determine how to launch the qemu robot test
#                       containers. The options as local, and k8s. It will
#                       default to local which will launch a single container
#                       to do the runs. If specified k8s will launch a group of
#                       containers into a kubernetes cluster using the helper
#                       script.
#
###############################################################################

set -uo pipefail

QEMU_RUN_TIMER=${QEMU_RUN_TIMER:-300}
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
DOCKER_IMG_NAME=${DOCKER_IMG_NAME:-openbmc/ubuntu-robot-qemu}
OBMC_BUILD_DIR=${OBMC_BUILD_DIR:-/tmp/openbmc/build}
UPSTREAM_WORKSPACE=${UPSTREAM_WORKSPACE:-${1}}
LAUNCH=${LAUNCH:-local}

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

# Get the base directory of the openbmc-build-scripts repo so we can return
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Create the base Docker image for QEMU and Robot
. "$DIR/scripts/build-qemu-robot-docker.sh" "$DOCKER_IMG_NAME"

# Copy the scripts to start and verify QEMU in the workspace
cp $DIR/scripts/boot-qemu* ${UPSTREAM_WORKSPACE}

# Move into the upstream workspace directory
cd ${UPSTREAM_WORKSPACE}
################################################################################

if [[ ${LAUNCH} == "local" ]]; then

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

  # We can use default ports because we're going to have the 2
  # docker instances talk over their private network
  DOCKER_SSH_PORT=22
  DOCKER_HTTPS_PORT=443
  DOCKER_QEMU_IP_ADDR="$(docker inspect $obmc_qemu_docker |  \
                       grep -m 1 "IPAddress\":" | cut -d '"' -f 4)"'

  #Now wait for the OpenBMC QEMU Docker instance to get to standby
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

  # Now run the Robot test

  # Timestamp for job
  echo "Robot Test started, $(date)"

  mkdir -p ${WORKSPACE}
  cd ${WORKSPACE}

  # Copy in the script which will execute the Robot tests
  cp $DIR/scripts/run-robot.sh ${WORKSPACE}

  # Run the Docker container to execute the Robot test cases
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

  # Now stop the QEMU Docker image
  docker stop $obmc_qemu_docker

elif [[ ${LAUNCH} == "k8s" ]]; then
  # Package the Upstream into an image based off the one created by the build-qemu-robot.sh
  # Dockerfile = $( cat << EOF
  
  source ./kubernetes/kubernetes-launch.sh QEMU-launch false false deployment

  # Xcat Launch
  
  # source ./kubernetes/kubernetes-launch.sh XCAT-launch true true 
  
else
  echo "LAUNCH variable invalid, Exiting"
  exit 1
fi
