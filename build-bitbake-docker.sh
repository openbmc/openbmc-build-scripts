#!/bin/bash
###############################################################################
#
# build-bitbake-docker.sh will configure and build the docker container
# used to run an OpenBMC build with run-bitbake-docker.sh.
#
###############################################################################
#
# Script Variables:
#  http_proxy         The HTTP address of the proxy server to connect to.
#                     Default: "", proxy is not setup if this is not set
#
# Docker Image Build Variables:
#  build_dir          Path where the actual BitBake build occurs inside the
#                     container, path cannot be located on network storage.
#                     Default: "/tmp/openbmc"
#  distro             The distro used as the base image for the build image:
#                     fedora|ubuntu
#                     Default: "ubuntu"
#  img_name           The name given to the target build's docker image.
#                     Default: "openbmc/${distro}:${imgtag}-${target}-${ARCH}"
#  img_tag            The base docker image distro tag:
#                     ubuntu: latest|16.04|14.04|trusty|xenial
#                     fedora: 23|24|25
#                     Default: "latest"
#  target             The target we aim to build:
#                     barreleye|evb-ast2500|firestone|garrison|palmetto|qemu
#                     romulus|s2600wf|witherspoon|zaius
#                     Default: "qemu"
#
###############################################################################
# Trace bash processing. Set -e so when a step fails, we fail the build
set -xeo pipefail

# Script Variables:
http_proxy=${http_proxy:-}

# Docker Image Build Variables:
build_dir=${build_dir:-/tmp/openbmc}
distro=${distro:-ubuntu}
img_tag=${img_tag:-latest}
target=${target:-qemu}

PROXY=""

# Determine the architecture
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

# Timestamp for job
echo "Docker Build started, $(date)"

# Configure Docker build
if [[ "${distro}" == fedora ]];then

  if [[ -n "${http_proxy}" ]]; then
    PROXY="RUN echo \"proxy=${http_proxy}\" >> /etc/dnf/dnf.conf"
  fi

  Dockerfile=$(cat << EOF
  FROM ${DOCKER_BASE}${distro}:${img_tag}

  ${PROXY}

  # Set the locale
  RUN locale-gen en_US.UTF-8
  ENV LANG en_US.UTF-8
  ENV LANGUAGE en_US:en
  ENV LC_ALL en_US.UTF-8

  RUN dnf --refresh install -y \
      bzip2 \
      chrpath \
      cpio \
      diffstat \
      findutils \
      gcc \
      gcc-c++ \
      git \
      make \
      patch \
      perl-bignum \
      perl-Data-Dumper \
      perl-Thread-Queue \
      python-devel \
      python3-devel \
      SDL-devel \
      socat \
      subversion \
      tar \
      texinfo \
      wget \
      which \
      iputils-ping

  RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
  RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

  USER ${USER}
  ENV HOME ${HOME}
  RUN /bin/bash
EOF
)

elif [[ "${distro}" == ubuntu ]]; then

  if [[ -n "${http_proxy}" ]]; then
    PROXY="RUN echo \"Acquire::http::Proxy \\"\"${http_proxy}/\\"\";\" > /etc/apt/apt.conf.d/000apt-cacher-ng-proxy"
  fi

  Dockerfile=$(cat << EOF
  FROM ${DOCKER_BASE}${distro}:${img_tag}

  ${PROXY}

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
      iputils-ping

  # Set the locale
  RUN locale-gen en_US.UTF-8
  ENV LANG en_US.UTF-8
  ENV LANGUAGE en_US:en
  ENV LC_ALL en_US.UTF-8

  RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
  RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

  USER ${USER}
  ENV HOME ${HOME}
  RUN /bin/bash
EOF
)
fi

# Give the Docker image a name based on the distro,tag,arch,and target
img_name=${img_name:-openbmc/${distro}:${img_tag}-${target}-${ARCH}}

# Build the Docker image
docker build -t ${img_name} - <<< "${Dockerfile}"

# Timestamp for build
echo "Docker Build completed, $(date)"
