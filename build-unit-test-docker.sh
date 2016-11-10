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
else
    DOCKER_BASE=""
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
    autoconf \
    libsystemd-dev \
    sudo \
    wget \
    git

RUN wget http://ftpmirror.gnu.org/autoconf-archive/autoconf-archive-2016.09.16.tar.xz
RUN tar -xJf autoconf-archive-2016.09.16.tar.xz
RUN cd autoconf-archive-2016.09.16 && ./configure --prefix=/usr && make && make install

RUN wget https://github.com/google/googletest/archive/release-1.7.0.tar.gz
RUN tar -xzf release-1.7.0.tar.gz
RUN cd googletest-release-1.7.0 && cmake -DBUILD_SHARED_LIBS=ON . && make && \
cp -a include/gtest /usr/include && \
cp -a libgtest_main.so libgtest.so /usr/lib/

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

RUN /bin/bash
EOF
)
fi
################################# docker img # #################################

# Build above image
docker build -t ${DOCKER_IMG_NAME} - <<< "${Dockerfile}"
