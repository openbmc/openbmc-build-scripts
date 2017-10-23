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

# Disable autom4te cache as workaround to permission issue
AUTOM4TE_CFG="/root/.autom4te.cfg"
AUTOM4TE="begin-language: \"Autoconf-without-aclocal-m4\"\nargs: --no-cache\n\
end-language: \"Autoconf-without-aclocal-m4\""

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
    python-git \
    python-yaml \
    python-mako \
    python-setuptools \
    python3 \
    python3-dev\
    python3-yaml \
    python3-mako \
    python3-setuptools \
    pkg-config \
    autoconf \
    libsystemd-dev \
    libssl-dev \
    libevdev-dev \
    sudo \
    wget \
    git \
    dbus \
    iputils-ping

RUN easy_install pip
RUN pip install inflection

RUN wget http://ftpmirror.gnu.org/autoconf-archive/autoconf-archive-2016.09.16.tar.xz
RUN tar -xJf autoconf-archive-2016.09.16.tar.xz
RUN cd autoconf-archive-2016.09.16 && ./configure --prefix=/usr && make && make install

RUN wget https://github.com/google/googletest/archive/release-1.8.0.tar.gz
RUN tar -xzf release-1.8.0.tar.gz
RUN cd googletest-release-1.8.0 && cmake -DBUILD_SHARED_LIBS=ON . && make && \
cp -a googletest/include/gtest /usr/include && \
cp -a googlemock/include/gmock /usr/include && \
cp -a googlemock/gtest/libgtest.so /usr/lib/ && \
cp -a googlemock/gtest/libgtest_main.so /usr/lib/ && \
cp -a googlemock/libgmock.so /usr/lib/ && \
cp -a googlemock/libgmock_main.so /usr/lib/

RUN wget https://github.com/USCiLab/cereal/archive/v1.2.2.tar.gz
RUN tar -xzf v1.2.2.tar.gz
RUN cp -a cereal-1.2.2/include/cereal/ /usr/include/

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

RUN echo '${AUTOM4TE}' > ${AUTOM4TE_CFG}

RUN /bin/bash
EOF
)
fi
################################# docker img # #################################

# Build above image
docker build -t ${DOCKER_IMG_NAME} - <<< "${Dockerfile}"
