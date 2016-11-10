#!/bin/bash -xe
#
# Build the required docker image to run package unit tests
#
#  Parameters:
#   parm1:  <optional, the name of the docker image to generate>
#            default is openbmc/ubuntu-unit-test

set -uo pipefail

DOCKER_IMG_NAME=${1:-"openbmc/ubuntu-unit-test"}

# Determine our architecture, ppc64le or the other one
if [ $(uname -m) == "ppc64le" ]; then
    DOCKER_BASE="ppc64le/"
else
    DOCKER_BASE=""
fi

# Add yakkety and zesty mirrors for more recent versions of packages
YAKKETY_MIRROR="deb http://mirrors.kernel.org/ubuntu yakkety main universe"
ZESTY_MIRROR="deb http://mirrors.kernel.org/ubuntu zesty main universe"

################################# docker img # #################################
# Create docker image that can run package unit tests
Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}ubuntu:latest

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
    autoconf \
    automake \
    pkg-config \
    libsystemd-dev \
    sudo \
    wget \
    git \
    vim

RUN echo ${YAKKETY_MIRROR} >> /etc/apt/sources.list
RUN echo ${ZESTY_MIRROR} >> /etc/apt/sources.list

RUN apt-get update && apt-get install -yy \
    autoconf-archive=20160916-1 \
    libgtest-dev

RUN cd /usr/src/gtest && sudo cmake . && sudo make && sudo mv libg* /usr/lib/

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} \
                    ${USER}
USER ${USER}
ENV HOME ${HOME}
RUN /bin/bash
EOF
)

################################# docker img # #################################

# Build above image
docker build -t ${DOCKER_IMG_NAME} - <<< "${Dockerfile}"
