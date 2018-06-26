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
    python-pip \
    python-setuptools \
    python3 \
    python3-dev\
    python3-yaml \
    python3-mako \
    python3-pip \
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
    iputils-ping \
    clang-format-5.0 \
    iproute2 \
    libnl-3-dev \
    libnl-genl-3-dev \
    libconfig++-dev \
    libsnmp-dev \
    valgrind \
    lcov \
    libpam0g-dev

RUN pip install inflection
RUN pip install pycodestyle

RUN wget http://ftpmirror.gnu.org/autoconf-archive/autoconf-archive-2016.09.16.tar.xz
RUN tar -xJf autoconf-archive-2016.09.16.tar.xz
RUN cd autoconf-archive-2016.09.16 && ./configure --prefix=/usr && make && make install

# Googletest doesn't support pkg-config properly and therefore yocto uses a
# patch to fix it.  This grabs and applies that patch and then builds it.
RUN wget https://github.com/google/googletest/archive/release-1.8.0.tar.gz
RUN tar -xzf release-1.8.0.tar.gz
RUN wget -O googletest-release-1.8.0/Add-pkg-config-support.patch \
http://cgit.openembedded.org/meta-openembedded/plain/meta-oe/recipes-test/gtest/gtest/Add-pkg-config-support.patch?h=rocko
RUN cd googletest-release-1.8.0 && patch -p1 -i Add-pkg-config-support.patch
RUN cd googletest-release-1.8.0 && \
cmake -DBUILD_SHARED_LIBS=ON -DCMAKE_INSTALL_PREFIX:PATH=/usr -DCMAKE_INSTALL_LIBDIR:PATH=/usr/lib -DCMAKE_INSTALL_INCLUDEDIR:PATH=/usr/include . && \
make && make install

RUN wget https://github.com/USCiLab/cereal/archive/v1.2.2.tar.gz
RUN tar -xzf v1.2.2.tar.gz
RUN cp -a cereal-1.2.2/include/cereal/ /usr/include/

RUN wget https://github.com/nlohmann/json/releases/download/v3.0.1/json.hpp
RUN mkdir /usr/include/nlohmann/
RUN cp -a json.hpp /usr/include/nlohmann/

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

RUN /bin/bash
EOF
)
fi
################################# docker img # #################################

# Build above image
docker build -t ${DOCKER_IMG_NAME} - <<< "${Dockerfile}"
