#!/bin/bash
###############################################################################
#
# This build script is for running the QEMU build as a container with the
# option of launching the container with Docker or Kubernetes.
#
###############################################################################
#
# Script Variables:
#  build_scripts_dir  The path of the openbmc-build-scripts directory.
#                     Default: The directory containing this script
#  http_proxy         The HTTP address of the proxy server to connect to.
#                     Default: "", proxy is not setup if this is not set
#  qemudir            Path of the directory that holds the QEMU repo, if none
#                     exists will clone in the OpenBMC/QEMU repo to WORKSPACE.
#                     Default: "${WORKSPACE}/qemu"
#  WORKSPACE          Path of the workspace directory where some intermediate
#                     files and the images will be saved to.
#                     Default: "~/{RandomNumber}"
#
# Docker Image Build Variables:
#  builddir           Path of the directory that is created within the docker
#                     container where the build is actually done. Done this way
#                     to allow NFS volumes to be used as the qemudir.
#                     Default: "/tmp/qemu"
#  imgname            Defaults to qemu-build with the arch as its tag, can be
#                     changed or passed to give a specific name to created image
#
# Deployment Variables:
#  launch             ""|job|pod
#                     Leave blank to launch via Docker if not using kubernetes
#                     to launch the container.
#                     Job lets you keep a copy of job and container logs on the
#                     api, can be useful if not using Jenkins as you can run the
#                     job again via the api without needing this script.
#                     Pod launches a container which runs to completion without
#                     saving anything to the api when it completes.
#
###############################################################################
build_scripts_dir=${build_scripts_dir:-"$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}

# Trace bash processing
set -x

# Default variables
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
http_proxy=${http_proxy:-}
launch=${launch:-}
qemudir=${qemudir:-${WORKSPACE}/qemu}
builddir=${builddir:-/tmp/qemu}
ARCH=$(uname -m)
imgname=${imgname:-qemu-build:${ARCH}}

# Timestamp for job
echo "Build started, $(date)"

# Setup Proxy
if [[ -n "${http_proxy}" ]]; then
PROXY="RUN echo \"Acquire::http::Proxy \\"\"${http_proxy}/\\"\";\" > /etc/apt/apt.conf.d/000apt-cacher-ng-proxy"
fi

# Determine the prefix of the Dockerfile's base image
case ${ARCH} in
  "ppc64le")
    DOCKER_BASE="ppc64le/"
    ;;
  "x86_64")
    DOCKER_BASE=""
    ;;
  *)
    echo "Unsupported system architecture(${ARCH}) found for docker image"
    exit 1
esac

# If there is no qemu directory, git clone in the openbmc mirror
if [ ! -d ${qemudir} ]; then
  echo "Clone in openbmc master to ${qemudir}"
  git clone https://github.com/openbmc/qemu ${qemudir}
fi

# Create the docker run script
export PROXY_HOST=${http_proxy/#http*:\/\/}
export PROXY_HOST=${PROXY_HOST/%:[0-9]*}
export PROXY_PORT=${http_proxy/#http*:\/\/*:}

mkdir -p ${WORKSPACE}

cat > "${WORKSPACE}"/build.sh << EOF_SCRIPT
#!/bin/bash

set -x

# create a copy of the qemudir in /qemu to use as the build directory
cp -a ${qemudir}/. ${builddir}

# Go into the build directory
cd ${builddir}

gcc --version
git submodule update --init dtc
# disable anything that requires us to pull in X
./configure \
    --target-list=arm-softmmu \
    --disable-spice \
    --disable-docs \
    --disable-gtk \
    --disable-smartcard \
    --disable-usb-redir \
    --disable-libusb \
    --disable-sdl \
    --disable-gnutls \
    --disable-vte \
    --disable-vnc \
    --disable-vnc-png
make -j4

cp -a ${builddir}/arm-softmmu/. ${WORKSPACE}/arm-softmmu/
EOF_SCRIPT

chmod a+x ${WORKSPACE}/build.sh

# Configure docker build
Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}ubuntu:16.04

${PROXY}

ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update && apt-get install -yy --no-install-recommends \
    bison \
    flex \
    gcc \
    git \
    libc6-dev \
    libfdt-dev \
    libglib2.0-dev \
    libpixman-1-dev \
    make \
    python-yaml \
    python3-yaml \
    iputils-ping

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}
USER ${USER}
RUN mkdir ${builddir}
ENV HOME ${HOME}
EOF
)

docker build -t ${imgname} - <<< "${Dockerfile}"
# If Launch is left empty will create a docker container
if [[ "${launch}" == "" ]]; then

  if [[ "$?" -ne 0 ]]; then
    echo "Failed to build docker container."
    exit 1
  fi
  mountqemu="-v ""${qemudir}"":""${qemudir}"" "
  if [[ "${qemudir}" = "${HOME}/"* || "${qemudir}" = "${HOME}" ]]; then
    mountqemu=""
  fi
  docker run \
      --rm=true \
      -e WORKSPACE=${WORKSPACE} \
      -w "${HOME}" \
      -v "${HOME}":"${HOME}" \
      ${mountqemu} \
      -t ${imgname} \
      ${WORKSPACE}/build.sh
elif [[ "${launch}" == "pod" || "${launch}" == "job" ]]; then
  . ${build_scripts_dir}/kubernetes/kubernetes-launch.sh QEMU-build true true
else
  echo "Launch Parameter is invalid"
fi
