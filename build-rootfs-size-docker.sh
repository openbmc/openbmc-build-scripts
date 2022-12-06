#!/bin/bash -xe
#
# Build the required docker image to run rootfs_size.py
#
# Script Variables:
#   DOCKER_IMG_NAME:  <optional, the name of the docker image to generate>
#                     default is openbmc/ubuntu-rootfs-size
#   DISTRO:           <optional, the distro to build a docker image against>
#   UBUNTU_MIRROR:    [optional] The URL of a mirror of Ubuntu to override the
#                     default ones in /etc/apt/sources.list
#                     default is empty, and no mirror is used.
#   http_proxy:       The HTTP address of the proxy server to connect to.
#                     Default: "", proxy is not setup if this is not set

http_proxy=${http_proxy:-}
UBUNTU_MIRROR=${UBUNTU_MIRROR:-""}

set -uo pipefail

DOCKER_IMG_NAME=${DOCKER_IMG_NAME:-"openbmc/ubuntu-rootfs-size"}
DISTRO=${DISTRO:-"ubuntu:bionic"}

# Determine the architecture
ARCH=$(uname -m)
case ${ARCH} in
    "ppc64le")
        DOCKER_BASE="ppc64le/"
        ;;
    "x86_64")
        DOCKER_BASE=""
        ;;
    "aarch64")
        DOCKER_BASE="arm64v8/"
        ;;
    *)
        echo "Unsupported system architecture(${ARCH}) found for docker image"
        exit 1
esac

PROXY=""

MIRROR=""
if [[ -n "${UBUNTU_MIRROR}" ]]; then
    MIRROR="RUN echo \"deb ${UBUNTU_MIRROR} \$(. /etc/os-release && echo \$VERSION_CODENAME) main restricted universe multiverse\" > /etc/apt/sources.list && \
        echo \"deb ${UBUNTU_MIRROR} \$(. /etc/os-release && echo \$VERSION_CODENAME)-updates main restricted universe multiverse\" >> /etc/apt/sources.list && \
        echo \"deb ${UBUNTU_MIRROR} \$(. /etc/os-release && echo \$VERSION_CODENAME)-security main restricted universe multiverse\" >> /etc/apt/sources.list && \
        echo \"deb ${UBUNTU_MIRROR} \$(. /etc/os-release && echo \$VERSION_CODENAME)-proposed main restricted universe multiverse\" >> /etc/apt/sources.list && \
        echo \"deb ${UBUNTU_MIRROR} \$(. /etc/os-release && echo \$VERSION_CODENAME)-backports main restricted universe multiverse\" >> /etc/apt/sources.list"
fi

################################# docker img # #################################

if [[ "${DISTRO}" == "ubuntu"* ]]; then

    if [[ -n "${http_proxy}" ]]; then
        PROXY="RUN echo \"Acquire::http::Proxy \\"\"${http_proxy}/\\"\";\" > /etc/apt/apt.conf.d/000apt-cacher-ng-proxy"
    fi

    Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}${DISTRO}

${PROXY}
${MIRROR}

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && apt-get install -yy \
    python3 \
    python3-dev\
    python3-yaml \
    python3-mako \
    python3-pip \
    python3-setuptools \
    curl \
    git \
    wget \
    sudo \
    squashfs-tools

# Final configuration for the workspace
RUN grep -q ${GROUPS[0]} /etc/group || groupadd -g ${GROUPS[0]} ${USER}
RUN mkdir -p $(dirname "${HOME}")
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS[0]} ${USER}
RUN sed -i '1iDefaults umask=000' /etc/sudoers
RUN echo "${USER} ALL=(ALL) NOPASSWD: ALL" >>/etc/sudoers

RUN /bin/bash
EOF
    )
fi
################################# docker img # #################################

# Build above image
docker build --network=host -t "${DOCKER_IMG_NAME}" - <<< "${Dockerfile}"
