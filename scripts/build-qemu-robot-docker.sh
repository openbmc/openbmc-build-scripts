#!/bin/bash -xe
#
# Build the required docker image to run QEMU and Robot test cases
#
#  Parameters:
#   parm1:  <optional, the name of the docker image to generate>
#            default is openbmc/ubuntu-robot-qemu
#   param2: <optional, the distro to build a docker image against>
#            default is ubuntu:artful

set -uo pipefail

DOCKER_IMG_NAME=${1:-"openbmc/ubuntu-robot-qemu"}
DISTRO=${2:-"ubuntu:artful"}

# Determine our architecture, ppc64le or the other one
if [ $(uname -m) == "ppc64le" ]; then
    DOCKER_BASE="ppc64le/"
else
    DOCKER_BASE=""
fi

################################# docker img # #################################
# Create docker image that can run QEMU and Robot Tests
Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}${DISTRO}

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && apt-get install -yy \
    debianutils \
    gawk \
    git \
    python \
    python-dev \
    python-setuptools \
    python3 \
    python3-dev \
    python3-setuptools \
    socat \
    texinfo \
    wget \
    gcc \
    libffi-dev \
    libssl-dev \
    xterm \
    mwm \
    ssh \
    vim \
    iputils-ping \
    sudo \
    cpio \
    unzip \
    diffstat \
    expect \
    curl \
    build-essential \
    libpixman-1-0 \
    libglib2.0-0 \
    sshpass \
    libasound2 \
    libfdt1 \
    libpcre3 \
    openssl \
    libxml2-dev \
    libxslt-dev \
    python3-pip

RUN easy_install \
    tox \
    pip \
    requests \
    lxml

RUN pip install \
    json2yaml \
    robotframework \
    robotframework-requests \
    robotframework-sshlibrary \
    robotframework-scplibrary \
    pysnmp \
    redfish

RUN pip3 install \
    beautifulsoup4

RUN wget https://sourceforge.net/projects/ipmitool/files/ipmitool/1.8.18/ipmitool-1.8.18.tar.bz2
RUN tar xvfj ipmitool-*.tar.bz2
RUN ./ipmitool-1.8.18/configure
RUN make
RUN make install

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
