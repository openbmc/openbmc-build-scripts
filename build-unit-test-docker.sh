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

# Setup temporary files
DEPCACHE_FILE=""
cleanup() {
  local status="$?"
  if [ -n "$DEPCACHE_FILE" ]; then
    rm -f "$DEPCACHE_FILE"
  fi
  trap - EXIT ERR
  exit "$status"
}
trap cleanup EXIT ERR INT TERM QUIT
DEPCACHE_FILE="$(mktemp)"

PKGS=(
  phosphor-objmgr
  sdbusplus
  sdeventplus
  gpioplus
  phosphor-logging
  phosphor-dbus-interfaces
  openpower-dbus-interfaces
)

# Generate a list of depcache entries
# We want to do this in parallel since the package list is growing
# and the network lookup is low overhead but decently high latency.
# This doesn't worry about producing a stable DEPCACHE_FILE, that is
# done by readers who need a stable ordering.
generate_depcache_entry() {
  local package="$1"

  local tip
  tip=$(git ls-remote "https://github.com/openbmc/${package}" |
        grep 'refs/heads/master' | awk '{ print $1 }')

  # Lock the file to avoid interlaced writes
  exec 3>> "$DEPCACHE_FILE"
  flock -x 3
  echo "$package:$tip" >&3
  exec 3>&-
}
for package in "${PKGS[@]}"; do
  generate_depcache_entry "$package" &
done
wait

# Define common flags used for builds
PREFIX="/usr/local"
CONFIGURE_FLAGS=(
  "--prefix=${PREFIX}"
)
CMAKE_FLAGS=(
  "-DCMAKE_BUILD_TYPE=RelWithDebInfo"
  "-DBUILD_SHARED_LIBS=ON"
  "-DCMAKE_INSTALL_PREFIX:PATH=${PREFIX}"
)

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
    libpng-dev \
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
    libi2c-dev \
    wget \
    libldap2-dev

RUN pip install inflection
RUN pip install pycodestyle

# Snapshot from 2018-06-14
RUN curl -L https://github.com/google/googletest/archive/ba96d0b1161f540656efdaed035b3c062b60e006.tar.gz | tar -xz && \
cd googletest-* && \
mkdir build && \
cd build && \
cmake ${CMAKE_FLAGS[@]} -DBUILD_GTEST=ON -DBUILD_GMOCK=ON .. && \
make && make install

RUN curl -L https://github.com/USCiLab/cereal/archive/v1.2.2.tar.gz | tar -xz && \
cp -a cereal-1.2.2/include/cereal/ /usr/local/include/

RUN mkdir /usr/local/include/nlohmann/ && \
curl -L -o /usr/local/include/nlohmann/json.hpp https://github.com/nlohmann/json/releases/download/v3.0.1/json.hpp

RUN curl -L https://dl.bintray.com/boostorg/release/1.66.0/source/boost_1_66_0.tar.bz2 | tar -xj && \
cp -a -r boost_1_66_0/boost /usr/local/include

# version from meta-openembedded/meta-oe/recipes-support/libtinyxml2/libtinyxml2_5.0.1.bb
RUN curl -L https://github.com/leethomason/tinyxml2/archive/37bc3aca429f0164adf68c23444540b4a24b5778.tar.gz | tar -xz && \
cd tinyxml2-* && \
mkdir build && \
cd build && \
cmake ${CMAKE_FLAGS[@]} .. && \
make -j$(nproc) && \
make install

# Fetch, build, and install latest libvncserver because obmc-ikvm requires a recent commit
# (libvncserver commit dd873fce451e4b7d7cc69056a62e107aae7c8e7a). This won't be included in any
# respository packages for some time.
RUN git clone https://github.com/LibVNC/libvncserver && \
cd libvncserver && \
mkdir build && \
cd build && \
cmake ${CMAKE_FLAGS[@]} .. && \
make -j$(nproc) && \
make install

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN mkdir -p $(dirname ${HOME})
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

RUN echo '${AUTOM4TE}' > ${AUTOM4TE_CFG}

# Sneaky use of Dockerfile semantics! Force a rebuild of the image if master
# has been updated in any of the repositories in \$PKGS: This happens as a
# consequence of the ls-remotes above, which will change the contents of
# \${DEPCACHE_FILE} and therefore trigger rebuilds of all of the following layers.
# NOTE: The file is sorted to ensure the ordering is stable.
RUN echo '$(sort "$DEPCACHE_FILE" | tr '\n' ',')' > /root/.depcache

RUN git clone https://github.com/openbmc/sdbusplus && \
cd sdbusplus && \
./bootstrap.sh && \
./configure ${CONFIGURE_FLAGS[@]} --enable-transaction && \
make -j$(nproc) && \
make install

RUN git clone https://github.com/openbmc/sdeventplus && \
cd sdeventplus && \
./bootstrap.sh && \
./configure ${CONFIGURE_FLAGS[@]} --disable-tests --disable-examples && \
make -j$(nproc) && \
make install

RUN git clone https://github.com/openbmc/gpioplus && \
cd gpioplus && \
./bootstrap.sh && \
./configure ${CONFIGURE_FLAGS[@]} --disable-tests --disable-examples && \
make -j$(nproc) && \
make install

RUN git clone https://github.com/openbmc/phosphor-dbus-interfaces && \
cd phosphor-dbus-interfaces && \
./bootstrap.sh && \
./configure ${CONFIGURE_FLAGS[@]} && \
make -j$(nproc) && \
make install

RUN git clone https://github.com/openbmc/openpower-dbus-interfaces && \
cd openpower-dbus-interfaces && \
./bootstrap.sh && \
./configure ${CONFIGURE_FLAGS[@]} && \
make -j$(nproc) && \
make install

RUN git clone https://github.com/openbmc/phosphor-logging && \
cd phosphor-logging && \
./bootstrap.sh && \
./configure ${CONFIGURE_FLAGS[@]} --enable-metadata-processing YAML_DIR=/usr/share/phosphor-dbus-yaml/yaml && \
make -j$(nproc) && \
make install

RUN git clone https://github.com/openbmc/phosphor-objmgr && \
cd phosphor-objmgr && \
./bootstrap.sh && \
./configure ${CONFIGURE_FLAGS[@]} --enable-unpatched-systemd && \
make -j$(nproc) && \
make install

RUN /bin/bash
EOF
)
fi
################################# docker img # #################################

# Build above image
docker build --network=host -t ${DOCKER_IMG_NAME} - <<< "${Dockerfile}"
