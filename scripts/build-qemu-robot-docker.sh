#!/bin/bash -xe
#
# Build the required docker image to run QEMU and Robot test cases

# Script Variables:
#  UBUNTU_MIRROR:    <optional, the URL of a mirror of Ubuntu to override the
#                    default ones in /etc/apt/sources.list>
#                    default is empty, and no mirror is used.
#  PIP_MIRROR:       <optional, the URL of a PIP mirror>
#                    default is empty, and no mirror is used.
#
#  Parameters:
#   parm1:  <optional, the name of the docker image to generate>
#            default is openbmc/ubuntu-robot-qemu
#   param2: <optional, the distro to build a docker image against>

set -uo pipefail

http_proxy=${http_proxy:-}

DOCKER_IMG_NAME=${1:-"openbmc/ubuntu-robot-qemu"}
DISTRO=${2:-"ubuntu:jammy"}
UBUNTU_MIRROR=${UBUNTU_MIRROR:-""}
PIP_MIRROR=${PIP_MIRROR:-""}

# Determine our architecture, ppc64le or the other one
if [ "$(uname -m)" == "ppc64le" ]; then
    DOCKER_BASE="ppc64le/"
else
    DOCKER_BASE=""
fi

MIRROR=""
if [[ -n "${UBUNTU_MIRROR}" ]]; then
    MIRROR="RUN echo \"deb ${UBUNTU_MIRROR} \$(. /etc/os-release && echo \$VERSION_CODENAME) main restricted universe multiverse\" > /etc/apt/sources.list && \
        echo \"deb ${UBUNTU_MIRROR} \$(. /etc/os-release && echo \$VERSION_CODENAME)-updates main restricted universe multiverse\" >> /etc/apt/sources.list && \
        echo \"deb ${UBUNTU_MIRROR} \$(. /etc/os-release && echo \$VERSION_CODENAME)-security main restricted universe multiverse\" >> /etc/apt/sources.list && \
        echo \"deb ${UBUNTU_MIRROR} \$(. /etc/os-release && echo \$VERSION_CODENAME)-proposed main restricted universe multiverse\" >> /etc/apt/sources.list && \
        echo \"deb ${UBUNTU_MIRROR} \$(. /etc/os-release && echo \$VERSION_CODENAME)-backports main restricted universe multiverse\" >> /etc/apt/sources.list"
fi

PIP_MIRROR_CMD=""
if [[ -n "${PIP_MIRROR}" ]]; then
    PIP_HOSTNAME=$(echo "${PIP_MIRROR}" | awk -F[/:] '{print $4}')
    PIP_MIRROR_CMD="RUN mkdir -p \${HOME}/.pip && \
        echo \"[global]\" > \${HOME}/.pip/pip.conf && \
        echo \"index-url=${PIP_MIRROR}\" >> \${HOME}/.pip/pip.conf &&\
        echo \"[install]\" >> \${HOME}/.pip/pip.conf &&\
        echo \"trusted-host=${PIP_HOSTNAME}\" >> \${HOME}/.pip/pip.conf"
fi

################################# docker img # #################################
# Create docker image that can run QEMU and Robot Tests
Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}${DISTRO}

${MIRROR}

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -yy \
    debianutils \
    gawk \
    git \
    python2 \
    python2-dev \
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
    libslirp-dev \
    openssl \
    libxml2-dev \
    libxslt-dev \
    python3-pip \
    ipmitool \
    xvfb \
    rustc

RUN apt-get update -qqy \
  && apt-get -qqy --no-install-recommends install firefox \
  && wget --no-verbose -O /tmp/firefox.tar.bz2 https://download-installer.cdn.mozilla.net/pub/firefox/releases/72.0/linux-x86_64/en-US/firefox-72.0.tar.bz2 \
  && apt-get -y purge firefox \
  && tar -C /opt -xjf /tmp/firefox.tar.bz2 \
  && mv /opt/firefox /opt/firefox-72.0 \
  && ln -fs /opt/firefox-72.0/firefox /usr/bin/firefox

ENV HOME ${HOME}

${PIP_MIRROR_CMD}

RUN pip3 install \
    tox \
    requests \
    retrying \
    websocket-client \
    json2yaml \
    robotframework \
    robotframework-requests \
    robotframework-jsonlibrary \
    robotframework-sshlibrary \
    robotframework-scplibrary \
    pysnmp \
    redfish>=3.1.7 \
    beautifulsoup4 --upgrade \
    lxml \
    jsonschema \
    redfishtool \
    redfish_utilities \
    robotframework-httplibrary \
    robotframework-seleniumlibrary \
    robotframework-xvfb \
    robotframework-angularjs \
    scp \
    selenium==3.141.0 \
    urllib3 \
    click \
    xvfbwrapper

RUN wget https://github.com/mozilla/geckodriver/releases/download/v0.29.0/geckodriver-v0.29.0-linux64.tar.gz \
        && tar xvzf geckodriver-*.tar.gz \
        && mv geckodriver /usr/local/bin \
        && chmod a+x /usr/local/bin/geckodriver

RUN grep -q ${GROUPS[0]} /etc/group || groupadd -g ${GROUPS[0]} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -l -m -u ${UID} -g ${GROUPS[0]} \
                    ${USER}
USER ${USER}
RUN /bin/bash
EOF
)

################################# docker img # #################################

PROXY_ARGS=""
if [[ -n "${http_proxy}" ]]; then
    PROXY_ARGS="--build-arg http_proxy=${http_proxy} --build-arg https_proxy=${http_proxy}"
fi

# Build above image
# shellcheck disable=SC2086 # PROXY_ARGS is intentionally word-split.
docker build ${PROXY_ARGS} -t "${DOCKER_IMG_NAME}" - <<< "${Dockerfile}"
