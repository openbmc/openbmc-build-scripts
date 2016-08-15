#!/bin/bash

# This build script is for running the Jenkins builds using docker.
#
# It expects a few variables which are part of Jenkins build job matrix:
#   target = barreleye|palmetto|qemu    (default qemu)
#   distro = fedora|ubuntu              (default ubuntu)
#   obmcdir = <name of openbmc src dir> (default openbmc)
#   WORKSPACE = <location of base openbmc/openbmc repo>

# Trace bash processing. Set -e so when a step fails, we fail the build
set -xeo pipefail

# Default variables
target=${target:-qemu}
distro=${distro:-ubuntu}
obmcdir=${obmcdir:-openbmc}
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
http_proxy=${http_proxy:-}
PROXY=""

# Determine our architecture, ppc64le or the other one
if [ $(uname -m) == "ppc64le" ]; then
    DOCKER_BASE="ppc64le/"
else
    DOCKER_BASE=""
fi

# Timestamp for job
echo "Build started, $(date)"

# Work out what build target we should be running and set bitbake command
case ${target} in
  barreleye)
    BITBAKE_CMD="TEMPLATECONF=meta-openbmc-machines/meta-openpower/meta-rackspace/meta-barreleye/conf source oe-init-build-env"
    ;;
  palmetto)
    BITBAKE_CMD="TEMPLATECONF=meta-openbmc-machines/meta-openpower/meta-ibm/meta-palmetto/conf source oe-init-build-env"
    ;;
  witherspoon)
    BITBAKE_CMD="TEMPLATECONF=meta-openbmc-machines/meta-openpower/meta-ibm/meta-witherspoon/conf source oe-init-build-env"
    ;;
  firestone)
    BITBAKE_CMD="TEMPLATECONF=meta-openbmc-machines/meta-openpower/meta-ibm/meta-firestone/conf source oe-init-build-env"
    ;;
  garrison)
    BITBAKE_CMD="TEMPLATECONF=meta-openbmc-machines/meta-openpower/meta-ibm/meta-garrison/conf source oe-init-build-env"
    ;;
  evb-ast2500)
    BITBAKE_CMD="TEMPLATECONF=meta-openbmc-machines/meta-evb/meta-evb-aspeed/meta-evb-ast2500/conf source oe-init-build-env"
    ;;
  qemu)
    BITBAKE_CMD="source openbmc-env"
    ;;
  *)
    exit 1
    ;;
esac

# Configure docker build
if [[ "${distro}" == fedora ]];then

  if [[ -n "${http_proxy}" ]]; then
    PROXY="RUN echo \"proxy=${http_proxy}\" >> /etc/dnf/dnf.conf"
  fi

  Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}fedora:latest

${PROXY}

RUN dnf --refresh install -y \
	bzip2 \
	chrpath \
	cpio \
	diffstat \
	findutils \
	gcc \
	gcc-c++ \
	git \
	make \
	patch \
	perl-bignum \
	perl-Data-Dumper \
	perl-Thread-Queue \
	python-devel \
	SDL-devel \
	socat \
	subversion \
	tar \
	texinfo \
	wget \
	which

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

USER ${USER}
ENV HOME ${HOME}
RUN /bin/bash
EOF
)

elif [[ "${distro}" == ubuntu ]]; then
  if [[ -n "${http_proxy}" ]]; then
    PROXY="RUN echo \"Acquire::http::Proxy \\"\"${http_proxy}/\\"\";\" > /etc/apt/apt.conf.d/000apt-cacher-ng-proxy"
  fi

  Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}ubuntu:latest

${PROXY}

ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update && apt-get install -yy \
	build-essential \
	chrpath \
	debianutils \
	diffstat \
	gawk \
	git \
	libdata-dumper-simple-perl \
	libsdl1.2-dev \
	libthread-queue-any-perl \
	python \
	socat \
	subversion \
	texinfo \
	cpio \
	wget

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

USER ${USER}
ENV HOME ${HOME}
RUN /bin/bash
EOF
)
fi

# Build the docker container
docker build -t openbmc/${distro} - <<< "${Dockerfile}"

# Create the docker run script
export PROXY_HOST=${http_proxy/#http*:\/\/}
export PROXY_HOST=${PROXY_HOST/%:[0-9]*}
export PROXY_PORT=${http_proxy/#http*:\/\/*:}

mkdir -p ${WORKSPACE}

cat > "${WORKSPACE}"/build.sh << EOF_SCRIPT
#!/bin/bash

set -xeo pipefail

cd ${WORKSPACE}

# Go into the openbmc directory (the openbmc script will put us in a build subdir)
cd ${obmcdir}

# Set up proxies
export ftp_proxy=${http_proxy}
export http_proxy=${http_proxy}
export https_proxy=${http_proxy}

mkdir -p ${WORKSPACE}/bin

# Configure proxies for bitbake
if [[ -n "${http_proxy}" ]]; then

  cat > ${WORKSPACE}/bin/git-proxy << \EOF_GIT
#!/bin/bash
# \$1 = hostname, \$2 = port
PROXY=${PROXY_HOST}
PROXY_PORT=${PROXY_PORT}
exec socat STDIO PROXY:\${PROXY}:\${1}:\${2},proxyport=\${PROXY_PORT}
EOF_GIT

  chmod a+x ${WORKSPACE}/bin/git-proxy
  export PATH=${WORKSPACE}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}
  git config core.gitProxy git-proxy

  mkdir -p ~/.subversion

  cat > ~/.subversion/servers << EOF_SVN
[global]
http-proxy-host = ${PROXY_HOST}
http-proxy-port = ${PROXY_PORT}
EOF_SVN
fi

# Source our build env
${BITBAKE_CMD}

# Custom bitbake config settings
cat >> conf/local.conf << EOF_CONF
BB_NUMBER_THREADS = "$(nproc)"
PARALLEL_MAKE = "-j$(nproc)"
INHERIT += "rm_work"
BB_GENERATE_MIRROR_TARBALLS = "1"
DL_DIR="${HOME}/bitbake_downloads"
SSTATE_DIR="${HOME}/bitbake_sharedstatecache"
USER_CLASSES += "buildstats"
EOF_CONF

# Kick off a build
bitbake obmc-phosphor-image

EOF_SCRIPT

chmod a+x ${WORKSPACE}/build.sh

# Run the docker container, execute the build script we just built
docker run --cap-add=sys_admin --net=host --rm=true -e WORKSPACE=${WORKSPACE} --user="${USER}" \
  -w "${HOME}" -v "${HOME}":"${HOME}" -t openbmc/${distro} ${WORKSPACE}/build.sh

# Create link to images for archiving
ln -sf ${WORKSPACE}/openbmc/build/tmp/deploy/images ${WORKSPACE}/images

# Timestamp for build
echo "Build completed, $(date)"

