#!/bin/bash -xe
#
# Build the required docker image to run package unit tests
#
# Parameters:
#   param1:  <optional, the name of the docker image to generate>
#            default is openbmc/ubuntu-unit-test
#   param2:  <optional, the distro to build a docker image against>
#            default is ubuntu:artful

set -uo pipefail

DOCKER_IMG_NAME=${1:-"openbmc/ubuntu-unit-test"}
DISTRO=${2:-"ubuntu:bionic"}

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

PKGS="phosphor-objmgr sdbusplus phosphor-logging phosphor-dbus-interfaces"
PKGS+=" openpower-dbus-interfaces"
DEPCACHE=
for package in $PKGS
do
    tip=$(git ls-remote https://github.com/openbmc/${package} |
           grep 'refs/heads/master' | awk '{ print $1 }')
    DEPCACHE+=${package}:${tip},
done

################################# docker img # #################################
# Create docker image that can run package unit tests
if [[ "${DISTRO}" == "ubuntu"* ]]; then
Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}${DISTRO}

ENV DEBIAN_FRONTEND noninteractive

# We need the keys to be imported for dbgsym repos
# New releases have a package, older ones fall back to manual fetching
# https://wiki.ubuntu.com/Debug%20Symbol%20Packages
RUN apt-get update && ( apt-get install ubuntu-dbgsym-keyring || ( apt-get install -yy dirmngr && \
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys F2EDC64DC5AEE1F6B9C621F0C8CAB6595FDFF622 ) )

# Parse the current repo list into a debug repo list
RUN sed -n '/^deb /s,^deb [^ ]* ,deb http://ddebs.ubuntu.com ,p' /etc/apt/sources.list >/etc/apt/sources.list.d/debug.list

# Remove non-existent debug repos
RUN sed -i '/-\(backports\|security\) /d' /etc/apt/sources.list.d/debug.list

RUN cat /etc/apt/sources.list.d/debug.list

RUN apt-get update && apt-get install -yy \
    gcc \
    g++ \
    libc6-dbg \
    libc6-dev \
    libtool \
    cmake \
    python \
    python-dev \
    python-git \
    python-yaml \
    python-mako \
    python-pip \
    python-setuptools \
    python-socks \
    python3 \
    python3-dev\
    python3-yaml \
    python3-mako \
    python3-pip \
    python3-setuptools \
    pkg-config \
    autoconf \
    autoconf-archive \
    libsystemd-dev \
    libsystemd0-dbgsym \
    libssl-dev \
    libevdev-dev \
    libevdev2-dbgsym \
    libjpeg-dev \
    sudo \
    curl \
    git \
    dbus \
    iputils-ping \
    clang-format-6.0 \
    iproute2 \
    libnl-3-dev \
    libnl-genl-3-dev \
    libconfig++-dev \
    libsnmp-dev \
    valgrind \
    valgrind-dbg \
    lcov \
    libpam0g-dev \
    xxd \
    wget

RUN pip install inflection
RUN pip install pycodestyle

# Snapshot from 2018-06-14
RUN curl -L -o googletest.tar.gz https://github.com/google/googletest/archive/ba96d0b1161f540656efdaed035b3c062b60e006.tar.gz
RUN tar -xzf googletest.tar.gz
RUN cd googletest-* && \
cmake -DBUILD_GTEST=ON -DBUILD_GMOCK=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBUILD_SHARED_LIBS=ON -DCMAKE_INSTALL_PREFIX:PATH=/usr . && \
make && make install

RUN curl -L -O https://github.com/USCiLab/cereal/archive/v1.2.2.tar.gz
RUN tar -xzf v1.2.2.tar.gz
RUN cp -a cereal-1.2.2/include/cereal/ /usr/include/

RUN curl -L -O https://github.com/nlohmann/json/releases/download/v3.0.1/json.hpp
RUN mkdir /usr/include/nlohmann/
RUN cp -a json.hpp /usr/include/nlohmann/

RUN curl -L -O https://dl.bintray.com/boostorg/release/1.66.0/source/boost_1_66_0.tar.bz2
RUN tar --bzip2 -xf boost_1_66_0.tar.bz2
RUN cp -a -r boost_1_66_0/boost /usr/include

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN mkdir -p $(dirname ${HOME})
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

RUN echo '${AUTOM4TE}' > ${AUTOM4TE_CFG}

# Sneaky use of Dockerfile semantics! Force a rebuild of the image if master
# has been updated in any of the repositories in $PKGS: This happens as a
# consequence of the ls-remotes above, which will change the value of
# ${DEPCACHE} and therefore trigger rebuilds of all of the following layers.
RUN echo '${DEPCACHE}' > /root/.depcache

RUN git clone https://github.com/openbmc/sdbusplus && \
cd sdbusplus && \
./bootstrap.sh && \
./configure --enable-transaction && \
make -j$(nproc) && \
make install

RUN git clone https://github.com/openbmc/phosphor-dbus-interfaces && \
cd phosphor-dbus-interfaces && \
./bootstrap.sh && \
./configure && \
make -j$(nproc) && \
make install

RUN git clone https://github.com/openbmc/openpower-dbus-interfaces && \
cd openpower-dbus-interfaces && \
./bootstrap.sh && \
./configure && \
make -j$(nproc) && \
make install

RUN git clone https://github.com/openbmc/phosphor-logging && \
cd phosphor-logging && \
./bootstrap.sh && \
./configure --enable-metadata-processing YAML_DIR=/usr/local/share/phosphor-dbus-yaml/yaml && \
make -j$(nproc) && \
make install

RUN git clone https://github.com/openbmc/phosphor-objmgr && \
cd phosphor-objmgr && \
./bootstrap.sh && \
./configure --enable-unpatched-systemd && \
make -j$(nproc) && \
make install

# Fetch, build, and install latest libvncserver because obmc-ikvm requires a recent commit
# (libvncserver commit dd873fce451e4b7d7cc69056a62e107aae7c8e7a). This won't be included in any
# respository packages for some time.
RUN git clone https://github.com/LibVNC/libvncserver && \
cd libvncserver && \
mkdir build && \
cd build && \
cmake .. && \
make -j$(nproc) && \
make install

RUN /bin/bash
EOF
)
fi
################################# docker img # #################################

# Build above image
docker build --network=host -t ${DOCKER_IMG_NAME} - <<< "${Dockerfile}"
