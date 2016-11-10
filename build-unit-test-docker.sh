#!/bin/bash -xe
#
# Build the required docker image to run package unit tests
#
# Parameters:
#   param1:  <optional, the name of the docker image to generate>
#            default is openbmc/ubuntu-unit-test
#   param2:  <optional, the distro to build a docker image against>
#            default is ubuntu:latest

set -uo pipefail

DOCKER_IMG_NAME=${1:-"openbmc/ubuntu-unit-test"}
DISTRO=${2:-"ubuntu:latest"}

# Determine our architecture, ppc64le or the other one
if [ $(uname -m) == "ppc64le" ]; then
    DOCKER_BASE="ppc64le/"
    ZESTY_MIRROR="deb http://ports.ubuntu.com/ubuntu-ports zesty main universe"
else
    DOCKER_BASE=""
    ZESTY_MIRROR="deb http://mirrors.kernel.org/ubuntu zesty main universe"
fi

################################# docker img # #################################
# Create docker image that can run package unit tests
if [[ "${DISTRO}" == "ubuntu"* ]]; then
Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}${DISTRO}

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && apt-get install -yy \
    gcc \
    g++ \
    libc6-dev \
    libtool \
    cmake \
    python \
    python-dev \
    python-setuptools \
    pkg-config \
    libsystemd-dev \
    sudo \
    wget \
    git

RUN echo ${ZESTY_MIRROR} >> /etc/apt/sources.list
RUN apt-get update && apt-get install -yy \
    autoconf-archive=20160916-1 \
    libgtest-dev=1.7.0-4ubuntu1

RUN cd /usr/src/gtest && cmake . && make && mv libg* /usr/lib/

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

RUN /bin/bash
EOF
)
fi
################################# docker img # #################################

# Build above image
docker build -t ${DOCKER_IMG_NAME} - <<< "${Dockerfile}"
