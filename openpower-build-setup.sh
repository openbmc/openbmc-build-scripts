#!/bin/bash

# This build script is for running the Jenkins builds using docker.
#
# It expects a few variables which are part of Jenkins build job matrix:
#   target = palmetto|qemu|habanero|firestone|garrison
#   distro = ubuntu
#   WORKSPACE =

# Trace bash processing
set -x

# Default variables
target=${target:-palmetto}
distro=${distro:-ubuntu}
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
http_proxy=${http_proxy:-}

# Timestamp for job
echo "Build started, $(date)"

# Configure docker build
if [[ "${distro}" == fedora ]];then

  Dockerfile=$(cat << EOF
FROM fedora:latest

RUN dnf --refresh upgrade -y && \
	dnf install -y vim gcc-c++ flex bison git ctags cscope expat-devel \
	patch zlib-devel zlib-static perl
RUN groupadd -g ${GROUPS} ${USER} && useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

USER ${USER}
ENV HOME ${HOME}
RUN /bin/bash
EOF
)

elif [[ "${distro}" == ubuntu ]]; then

  Dockerfile=$(cat << EOF
FROM ubuntu:15.10

ENV DEBIAN_FRONTEND noninteractive
RUN echo $(date +%s) && apt-get update && \
	apt-get install -y \
	cscope ctags libz-dev libexpat-dev python language-pack-en texinfo \
	build-essential g++ git bison flex unzip libxml-simple-perl \
	libxml-sax-perl libxml2-dev libxml2-utils xsltproc
RUN groupadd -g ${GROUPS} ${USER} && useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

USER ${USER}
ENV HOME ${HOME}
RUN /bin/bash
EOF
)
fi

# Build the docker container
docker build -t op-build/${distro} - <<< "${Dockerfile}"
if [[ "$?" -ne 0 ]]; then
  echo "Failed to build docker container."
  exit 1
fi

mkdir -p ${WORKSPACE}

cat > "${WORKSPACE}"/build.sh << EOF_SCRIPT
#!/bin/bash

set -x

# This ensures that the alias set in op-build-env is
# avalaible in this script
shopt -s expand_aliases

cd ${WORKSPACE}/op-build

# Source our build env
. op-build-env

# Configure
op-build ${target}_defconfig

# Kick off a build
op-build

EOF_SCRIPT

chmod a+x ${WORKSPACE}/build.sh

# Run the docker container, execute the build script we just built
docker run --net=host --rm=true -e WORKSPACE=${WORKSPACE} --user="${USER}" \
  -w "${HOME}" -v "${HOME}":"${HOME}" -t op-build/${distro} ${WORKSPACE}/build.sh

# Create link to images for archiving
ln -sf ${WORKSPACE}/op-build/output/images ${WORKSPACE}/images

# Timestamp for build
echo "Build completed, $(date)"
