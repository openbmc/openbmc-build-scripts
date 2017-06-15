#!/bin/bash

# This build script is for running the Jenkins builds using docker.

# Trace bash processing
set -x

# Default variables
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
http_proxy=${http_proxy:-}
launch=${launch:-}

# Timestamp for job
echo "Build started, $(date)"

# Setup Proxy
if [[ -n "${http_proxy}" ]]; then
PROXY="RUN echo \"Acquire::http::Proxy \\"\"${http_proxy}/\\"\";\" > /etc/apt/apt.conf.d/000apt-cacher-ng-proxy"
fi

ARCH=$(uname -m)

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

# Create the docker run script
export PROXY_HOST=${http_proxy/#http*:\/\/}
export PROXY_HOST=${PROXY_HOST/%:[0-9]*}
export PROXY_PORT=${http_proxy/#http*:\/\/*:}

mkdir -p ${WORKSPACE}

cat > "${WORKSPACE}"/build.sh << EOF_SCRIPT
#!/bin/bash

set -x

cd ${WORKSPACE}

gcc --version

# Go into the source directory (the script will put us in a build subdir)
cd qemu
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
    python3-yaml

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}
USER ${USER}
ENV HOME ${HOME}
EOF
)

# Build the docker container
imgname=${imgname:-qemu-build:${ARCH}}

# If Launch is left empty will create a docker container
if [[ "${launch}" == "" ]]; then

  docker build -t ${imgname} .
  if [[ "$?" -ne 0 ]]; then
    echo "Failed to build docker container."
    exit 1
  fi

  docker run \
      --rm=true \
      -e WORKSPACE=${WORKSPACE} \
      -w "${HOME}" \
      -v "${HOME}":"${HOME}" \
      -t ${imgname} \
      ${WORKSPACE}/build.sh

else
  echo "Launch Parameter is invalid"
fi


