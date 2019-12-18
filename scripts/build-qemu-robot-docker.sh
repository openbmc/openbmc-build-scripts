#!/bin/bash -xe
#
# Build the required docker image to run QEMU and Robot test cases
#
#  Parameters:
#   parm1:  <optional, the name of the docker image to generate>
#            default is openbmc/ubuntu-robot-qemu
#   param2: <optional, the distro to build a docker image against>
#            default is ubuntu:bionic

set -uo pipefail

DOCKER_IMG_NAME=${1:-"openbmc/ubuntu-robot-qemu"}
DISTRO=${2:-"ubuntu:bionic"}

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
    python3-pip \
    ipmitool \
    xvfb

RUN apt-get update -qqy \
  && apt-get -qqy --no-install-recommends install firefox \
  && wget --no-verbose -O /tmp/firefox.tar.bz2 https://download-installer.cdn.mozilla.net/pub/firefox/releases/72.0/linux-x86_64/en-US/firefox-72.0.tar.bz2 \
  && apt-get -y purge firefox \
  && tar -C /opt -xjf /tmp/firefox.tar.bz2 \
  && mv /opt/firefox /opt/firefox-72.0 \
  && ln -fs /opt/firefox-72.0/firefox /usr/bin/firefox

RUN pip3 install \
    tox \
    requests \
    retrying \
    websocket-client \
    json2yaml \
    robotframework \
    robotframework-requests \
    robotframework-sshlibrary \
    robotframework-scplibrary \
    pysnmp \
    redfish \
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
    xvfbwrapper

RUN wget https://github.com/mozilla/geckodriver/releases/download/v0.26.0/geckodriver-v0.26.0-linux64.tar.gz \
        && tar xvzf geckodriver-*.tar.gz \
        && mv geckodriver /usr/local/bin \
        && chmod a+x /usr/local/bin/geckodriver

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
