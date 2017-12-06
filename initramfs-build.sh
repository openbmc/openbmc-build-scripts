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
FROM ubuntu:latest

${PROXY}

ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update && apt-get install -yy \
	bc \
	build-essential \
	cpio \
	git \
	python \
	unzip \
	wget \
	iputils-ping

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

RUN locale-gen en_AU.utf8

USER ${USER}
ENV HOME ${HOME}
RUN /bin/bash
EOF
)

# Build the docker container
docker build -t initramfs-build/ubuntu - <<< "${Dockerfile}"
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
cd buildroot

cat > configs/powerpc64_openpower_defconfig << EOF_BUILDROOT
BR2_powerpc64le=y
BR2_TARGET_ROOTFS_CPIO=y
BR2_TARGET_ROOTFS_CPIO_XZ=y
BR2_TARGET_GENERIC_GETTY_PORT="hvc0"
BR2_GLIBC_VERSION_2_22=y
EOF_BUILDROOT

# Build buildroot
export BR2_DL_DIR=${HOME}/buildroot_downloads
make powerpc64_openpower_defconfig || exit 1
make || exit 1

EOF_SCRIPT

chmod a+x ${WORKSPACE}/build.sh

# Run the docker container, execute the build script we just built
docker run --cap-add=sys_admin --net=host --rm=true -e WORKSPACE=${WORKSPACE} --user="${USER}" \
  -w "${HOME}" -v "${HOME}":"${HOME}" -t initramfs-build/ubuntu ${WORKSPACE}/build.sh

# Timestamp for build
echo "Build completed, $(date)"

