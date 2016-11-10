#!/bin/bash

# This build script is for running the Jenkins builds using docker.

# Trace bash processing
set -x

# Default variables
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
DEFCONFIG=${DEFCONFIG:-aspeed_g5_defconfig}
http_proxy=${http_proxy:-}

# Timestamp for job
echo "Build started, $(date)"

# Configure docker build
if [[ -n "${http_proxy}" ]]; then
PROXY="RUN echo \"Acquire::http::Proxy \\"\"${http_proxy}/\\"\";\" > /etc/apt/apt.conf.d/000apt-cacher-ng-proxy"
fi

Dockerfile=$(cat << EOF
FROM ubuntu:16.10

${PROXY}

ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update && apt-get install -yy \
	make build-essential bc gcc-arm-linux-gnueabi

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

USER ${USER}
ENV HOME ${HOME}
RUN /bin/bash
EOF
)

# Build the docker container
docker build -t linux-openbmc-build/ubuntu - <<< "${Dockerfile}"
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

gcc --version
arm-linux-gnueabi-gcc --version

ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- make ${DEFCONFIG}
ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- make

EOF_SCRIPT

chmod a+x ${WORKSPACE}/build.sh

# Run the docker container, execute the build script we just built
docker run --rm=true -e WORKSPACE=${WORKSPACE} --user="${USER}" \
  -w "${HOME}" -v "${HOME}":"${HOME}" -t linux-openbmc-build/ubuntu ${WORKSPACE}/build.sh
