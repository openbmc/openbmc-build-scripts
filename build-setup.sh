#!/bin/bash
###############################################################################
#
# This build script is for running the OpenBMC builds as containers with the
# option of launching the containers with Docker or Kubernetes.
#
###############################################################################
#
# Variables used for Jenkins build job matrix:
#  target       = barreleye|palmetto|witherspoon|firestone|garrison|evb-ast2500
#                 zaius|romulus|qemu
#  distro       = fedora|ubuntu|
#  imgtag       = varies by distro, latest; 16.04|14.04|trusty|xenial; 23|24|25
#  ocache       = path of the OpenBMC repo cache that is used to speed up git
#                 clones, default directory location "/home/openbmc"
#  obmcdir      = path of the OpenBMC directory, where the build occurs inside
#                 the container cannot be placed on external storage default
#                 directory location "/tmp/openbmc"
#  sscdir       = path of the BitBake shared-state cache directoy, will default
#                 to directory "/home/sstate-cache", used to speed up builds
#  WORKSPACE    = path of the workspace directory where some intermediate files
#                 and the images will be saved to
#
# Optional Variables:
#  launch       = job|pod, can be left blank to launch via Docker if not using
#                 Kubernetes to launch the container
#  imgname      = defaults to a relatively long but descriptive name, can be
#                 changed or passed to give a specific name to created image
#  BITBAKE_OPTS = set to "-c populate_sdk" or whatever other bitbake options
#                 you'd like to pass into the build
#
###############################################################################

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

# If there's no openbmc dir in WORKSPACE then just clone in master
if [ ! -d ${WORKSPACE}/${obmcdir} ]; then
    echo "Clone in openbmc master to ${WORKSPACE}/${obmcdir}"
    git clone https://github.com/openbmc/openbmc ${WORKSPACE}/${obmcdir}
fi

# if user just passed in ubuntu then use latest
if [[ $distro == "ubuntu" ]]; then
    distro="ubuntu:latest"
fi

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
  zaius)
    BITBAKE_CMD="TEMPLATECONF=meta-openbmc-machines/meta-openpower/meta-ingrasys/meta-zaius/conf source oe-init-build-env"
    ;;
  romulus)
    BITBAKE_CMD="TEMPLATECONF=meta-openbmc-machines/meta-openpower/meta-ibm/meta-romulus/conf source oe-init-build-env"
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

# Set the locale
RUN locale-gen en_US.UTF-8
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

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
	python3-devel \
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

elif [[ "${distro}" == "ubuntu"* ]]; then
  if [[ -n "${http_proxy}" ]]; then
    PROXY="RUN echo \"Acquire::http::Proxy \\"\"${http_proxy}/\\"\";\" > /etc/apt/apt.conf.d/000apt-cacher-ng-proxy"
  fi

  Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}${distro}

${PROXY}

ENV DEBIAN_FRONTEND noninteractive

# Set the locale
RUN locale-gen en_US.UTF-8
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

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
	python3 \
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
INHERIT_remove = "uninative"
EOF_CONF

# Kick off a build
bitbake ${BITBAKE_OPTS} obmc-phosphor-image

EOF_SCRIPT

chmod a+x ${WORKSPACE}/build.sh

# Run the docker container, execute the build script we just built
docker run --cap-add=sys_admin --net=host --rm=true -e WORKSPACE=${WORKSPACE} --user="${USER}" \
  -w "${HOME}" -v "${HOME}":"${HOME}" -t openbmc/${distro} ${WORKSPACE}/build.sh

# Create link to images for archiving
ln -sf ${WORKSPACE}/openbmc/build/tmp/deploy/images ${WORKSPACE}/images

# Timestamp for build
echo "Build completed, $(date)"

