#!/bin/bash

# This build script is for running the Jenkins builds using docker.
#

# Trace bash processing
#set -x

# Default variables
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
http_proxy=${http_proxy:-}

# Timestamp for job
echo "Build started, $(date)"

# Configure docker build
if [[ -n "${http_proxy}" ]]; then
PROXY="RUN echo \"Acquire::http::Proxy \\"\"${http_proxy}/\\"\";\" > /etc/apt/apt.conf.d/000apt-cacher-ng-proxy"
fi

Dockerfile=$(cat << EOF
FROM ubuntu:15.10

${PROXY}

# If we need to fetch new apt repo data, update the timestamp
RUN echo 201603031716 && apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get upgrade -yy
RUN DEBIAN_FRONTEND=noninteractive apt-get install -yy bc build-essential git gcc-powerpc64le-linux-gnu
RUN DEBIAN_FRONTEND=noninteractive apt-get install -yy software-properties-common
RUN apt-add-repository -y multiverse
# If we need to fetch new apt repo data, update the timestamp
RUN echo 201603031716 && apt-get update
RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get install -yy dwarves sparse
RUN groupadd -g ${GROUPS} ${USER} && useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

USER ${USER}
ENV HOME ${HOME}
RUN /bin/bash
EOF
)

# Build the docker container
docker build -t linux-build/ubuntu - <<< "${Dockerfile}"
if [[ "$?" -ne 0 ]]; then
  echo "Failed to build docker container."
  exit 1
fi

# Create the docker run script
export PROXY_HOST=${http_proxy/#http*:\/\/}
export PROXY_HOST=${PROXY_HOST/%:[0-9]*}
export PROXY_PORT=${http_proxy/#http*:\/\/*:}

mkdir -p ${WORKSPACE}

cat > "${WORKSPACE}"/build.sh << EOF_SCRIPT
#!/bin/bash

set -x

cd ${WORKSPACE}

# Go into the linux directory (the script will put us in a build subdir)
cd linux

# Record the version in the logs
powerpc64le-linux-gnu-gcc --version || exit 1

# Build kernel prep
ARCH=powerpc CROSS_COMPILE=powerpc64le-linux-gnu- make clean || exit 1
ARCH=powerpc CROSS_COMPILE=powerpc64le-linux-gnu- make mrproper || exit 1

# Build kernel with debug
ARCH=powerpc CROSS_COMPILE=powerpc64le-linux-gnu- make pseries_le_defconfig || exit 1
echo "CONFIG_DEBUG_INFO=y" >> .config
ARCH=powerpc CROSS_COMPILE=powerpc64le-linux-gnu- make olddefconfig || exit 1
ARCH=powerpc CROSS_COMPILE=powerpc64le-linux-gnu- make -j$(nproc) -s C=2 CF=-D__CHECK_ENDIAN__ 2>&1 | gzip > sparse.log.gz
pahole vmlinux 2>&1 | gzip > structs.dump.gz

# Build kernel
ARCH=powerpc CROSS_COMPILE=powerpc64le-linux-gnu- make pseries_le_defconfig || exit 1
ARCH=powerpc CROSS_COMPILE=powerpc64le-linux-gnu- make -j$(nproc) || exit 1

EOF_SCRIPT

chmod a+x ${WORKSPACE}/build.sh

# Run the docker container, execute the build script we just built
docker run --cap-add=sys_admin --net=host --rm=true -e WORKSPACE=${WORKSPACE} --user="${USER}" \
  -w "${HOME}" -v "${HOME}":"${HOME}" -t linux-build/ubuntu ${WORKSPACE}/build.sh

# Timestamp for build
echo "Build completed, $(date)"

