#!/bin/bash
###############################################################################
#
# This build script is for running the OpenBMC builds as containers with the
# option of launching the containers with Docker or Kubernetes.
#
###############################################################################
#
# Script Variables:
#  build_scripts_dir  The path of the openbmc-build-scripts directory.
#                     Default: The directory containing this script
#  http_proxy         The HTTP address of the proxy server to connect to.
#                     Default: "", proxy is not setup if this is not set
#  WORKSPACE          Path of the workspace directory where some intermediate
#                     files and the images will be saved to.
#                     Default: "~/{RandomNumber}"
#
# Docker Image Build Variables:
#  BITBAKE_OPTS       Set to "-c populate_sdk" or whatever other bitbake options
#                     you'd like to pass into the build.
#                     Default: "", no options set
#  builddir           Path where the actual bitbake build occurs in inside the
#                     container, path cannot be located on network storage.
#                     Default: "/tmp/openbmc"
#  distro             The distro used as the base image for the build image:
#                     fedora|ubuntu
#                     Default: "ubuntu"
#  imgname            The name given to the target build's docker image.
#                     Default: "openbmc/${distro}:${imgtag}-${target}-${ARCH}"
#  imgtag             The base docker image distro tag:
#                     ubuntu: latest|16.04|14.04|trusty|xenial
#                     fedora: 23|24|25
#                     Default: "latest"
#  target             The target we aim to build:
#                     barreleye|evb-ast2500|firestone|garrison|palmetto|qemu
#                     romulus|witherspoon|zaius
#                     Default: "qemu"
#
# Deployment Variables:
#  extraction         Path where the ombcdir contents will be copied out to when
#                     the build completes.
#                     Default: "${obmcext}/build/tmp"
#  launch             ""|job|pod
#                     Can be left blank to launch the container via Docker
#                     Job lets you keep a copy of job and container logs on the
#                     api, can be useful if not using Jenkins as you can run the
#                     job again via the api without needing this script.
#                     Pod launches a container which runs to completion without
#                     saving anything to the api when it completes.
#  obmcext            Path of the OpenBMC repo directory used as a reference
#                     for the build inside the container.
#                     Default: "${WORKSPACE}/openbmc"
#  sscdir             Path to use as the BitBake shared-state cache directory.
#                     Default: "/home/${USER}"
#
###############################################################################
build_scripts_dir=${build_scripts_dir:-"$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}

# Trace bash processing. Set -e so when a step fails, we fail the build
set -xeo pipefail

# Default variables
target=${target:-qemu}
distro=${distro:-ubuntu}
imgtag=${imgtag:-latest}
builddir=${builddir:-/tmp/openbmc}
sscdir=${sscdir:-${HOME}}
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
obmcext=${obmcext:-${WORKSPACE}/openbmc}
extraction=${extraction:-${obmcext}/build/tmp}
launch=${launch:-}
http_proxy=${http_proxy:-}
PROXY=""

# Determine the architecture
ARCH=$(uname -m)

# Determine the prefix of the Dockerfile's base image
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

# Timestamp for job
echo "Build started, $(date)"

# If the obmcext directory doesn't exist clone it in
if [ ! -d ${obmcext} ]; then
  echo "Clone in openbmc master to ${obmcext}"
  git clone https://github.com/openbmc/openbmc ${obmcext}
fi

# Make and chown the extraction directory to avoid permission errors
if [ ! -d ${extraction} ]; then
  mkdir -p ${extraction}
fi
chown ${UID}:${GROUPS} ${extraction}

# Work out what build target we should be running and set BitBake command
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

# Configure Docker build
if [[ "${distro}" == fedora ]];then

  if [[ -n "${http_proxy}" ]]; then
    PROXY="RUN echo \"proxy=${http_proxy}\" >> /etc/dnf/dnf.conf"
  fi

  Dockerfile=$(cat << EOF
  FROM ${DOCKER_BASE}${distro}:${imgtag}

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
      which \
      iputils-ping

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
  FROM ${DOCKER_BASE}${distro}:${imgtag}

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
      locales \
      python \
      python3 \
      socat \
      subversion \
      texinfo \
      cpio \
      wget \
      iputils-ping

  # Set the locale
  RUN locale-gen en_US.UTF-8
  ENV LANG en_US.UTF-8
  ENV LANGUAGE en_US:en
  ENV LC_ALL en_US.UTF-8

  RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
  RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

  USER ${USER}
  ENV HOME ${HOME}
  RUN /bin/bash
EOF
)
fi

# Create the Docker run script
export PROXY_HOST=${http_proxy/#http*:\/\/}
export PROXY_HOST=${PROXY_HOST/%:[0-9]*}
export PROXY_PORT=${http_proxy/#http*:\/\/*:}

mkdir -p ${WORKSPACE}

cat > "${WORKSPACE}"/build.sh << EOF_SCRIPT
#!/bin/bash

set -xeo pipefail

# Go into the OpenBMC directory, the build will handle changing directories
cd ${obmcext}

# Set up proxies
export ftp_proxy=${http_proxy}
export http_proxy=${http_proxy}
export https_proxy=${http_proxy}

mkdir -p ${WORKSPACE}/bin

# Configure proxies for BitBake
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

# Custom BitBake config settings
cat >> conf/local.conf << EOF_CONF
BB_NUMBER_THREADS = "$(nproc)"
PARALLEL_MAKE = "-j$(nproc)"
INHERIT += "rm_work"
BB_GENERATE_MIRROR_TARBALLS = "1"
DL_DIR="${sscdir}/bitbake_downloads"
SSTATE_DIR="${sscdir}/bitbake_sharedstatecache"
USER_CLASSES += "buildstats"
INHERIT_remove = "uninative"
TMPDIR="${builddir}"
EOF_CONF

# Kick off a build
bitbake ${BITBAKE_OPTS} obmc-phosphor-image

# Copy build directory of internal obmcdir into workspace directory
cp -r ${builddir}/* ${extraction}
EOF_SCRIPT

chmod a+x ${WORKSPACE}/build.sh

# Give the Docker image a name based on the distro,tag,arch,and target
imgname=${imgname:-openbmc/${distro}:${imgtag}-${target}-${ARCH}}

# Build the Docker image
docker build -t ${imgname} - <<< "${Dockerfile}"

# Determine if the build container will be launched with Docker or Kubernetes
if [[ "${launch}" == "" ]]; then

  # If obmcext or sscdir are ${HOME} or a subdirectory they will not be mounted
  mountobmcext="-v ""${obmcext}"":""${obmcext}"" "
  mountsscdir="-v ""${sscdir}"":""${sscdir}"" "
  if [[ "${obmcext}" = "${HOME}/"* || "${obmcext}" = "${HOME}" ]];then
    mountobmcext=""
  fi
  if [[ "${sscdir}" = "${HOME}/"* || "${sscdir}" = "${HOME}" ]];then
    mountsscdir=""
  fi

  # Run the Docker container, execute the build.sh script
  docker run \
  --cap-add=sys_admin \
  --net=host \
  --rm=true \
  -e WORKSPACE=${WORKSPACE} \
  -w "${HOME}" \
  -v "${HOME}":"${HOME}" \
  ${mountobmcext} \
  ${mountsscdir} \
  -t ${imgname} \
  ${WORKSPACE}/build.sh

elif [[ "${launch}" == "job" || "${launch}" == "pod" ]]; then

  # Source and run the helper script to launch the pod or job
  . ${build_scripts_dir}/kubernetes/kubernetes-launch.sh OpenBMC-build true true

else
  echo "Launch Parameter is invalid"
fi

# To maintain function of resources that used an older path, add a link
ln -sf ${extraction}/deploy ${WORKSPACE}/deploy

# Timestamp for build
echo "Build completed, $(date)"
