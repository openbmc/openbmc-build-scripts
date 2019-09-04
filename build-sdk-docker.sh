#!/usr/bin/env bash
#
# Grab latest SDK for input target and install into a docker container
#
# note that the SDK is downloaded from:
#    https://openpower.xyz/job/openbmc-build-sdk/
# so the input TARGET needs to be one of the supported machines at that link
#
# SDK will be installed to /usr/local/openbmc/sdk/${TARGET}/
# To use: . /usr/local/openbmc/sdk/${TARGET}/environment-setup-armv6-openbmc-linux-gnueabi
#
# Script Variables:
#   DOCKER_IMG_NAME:  <optional, the name of the docker image to generate>
#                     default is openbmc/ubuntu-sdk-${TARGET}
#   TARGET:           <optional, the openbmc target to retrieve the SDK for>
#                     default is romulus

set -xeuo pipefail

TARGET=${TARGET:-"romulus"}
DOCKER_IMG_NAME=${DOCKER_IMG_NAME:-"openbmc/ubuntu-sdk"}
DOCKER_IMG_NAME+="-${TARGET}"

# Determine the architecture
ARCH=$(uname -m)
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

################################# docker img # #################################
# Create docker image with SDK in it
Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}"ubuntu:eoan"

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && apt-get install -yy \
    build-essential \
    chrpath \
    debianutils \
    diffstat \
    gawk \
    git \
    libdata-dumper-simple-perl \
    libsdl1.2-dev \
    libthread-queue-any-perl \
    locales \
    python \
    python3 \
    socat \
    subversion \
    texinfo \
    cpio \
    wget \
    iputils-ping \
    vim

# Set the locale
RUN locale-gen en_US.UTF-8
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8


# Need fix for https://github.com/docker/hub-feedback/issues/727
RUN wget https://openpower.xyz/job/openbmc-build-sdk/distro=ubuntu,target=${TARGET}/lastSuccessfulBuild/artifact/deploy/sdk/oecore-x86_64-armv6-toolchain-nodistro.0.sh && \
chmod u+rwx *.sh && \
./oecore-x86_64-armv6-toolchain-nodistro.0.sh -d /usr/local/openbmc/sdk/${TARGET}/ -y

# Final configuration for the workspace
RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN mkdir -p "$(dirname "${HOME}")"
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}
RUN sed -i '1iDefaults umask=000' /etc/sudoers
RUN echo "${USER} ALL=(ALL) NOPASSWD: ALL" >>/etc/sudoers

RUN /bin/bash
EOF
)
################################# docker img # #################################

# Build above image
docker build --network=host -t ${DOCKER_IMG_NAME} - <<< "${Dockerfile}"
