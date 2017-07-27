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
#  distro       = fedora|ubuntu
#  imgtag       = Varies by distro. latest|16.04|14.04|trusty|xenial; 23|24|25
#  obmcext      = Path of the OpenBMC repo directory used in creating a copy
#                 inside the container that is not mounted to external storage
#                 default directory location "${WORKSPACE}/openbmc"
#  obmcdir      = Path of the OpenBMC directory, where the build occurs inside
#                 the container cannot be placed on external storage default
#                 directory location "/tmp/openbmc"
#  sscdir       = Path of the BitBake shared-state cache directoy, will default
#                 to directory "/home/${USER}", used to speed up builds.
#  WORKSPACE    = Path of the workspace directory where some intermediate files
#                 and the images will be saved to.
#
# Optional Variables:
#  launch       = job|pod
#                 Can be left blank to launch via Docker if not using
#                 Kubernetes to launch the container.
#                 Job lets you keep a copy of job and container logs on the
#                 api, can be useful if not using Jenkins as you can run the
#                 job again via the api without needing this script.
#                 Pod launches a container which runs to completion without
#                 saving anything to the api when it completes.
#  imgname      = Defaults to a relatively long but descriptive name, can be
#                 changed or passed to give a specific name to created image.
#  http_proxy   = The HTTP address for the proxy server you wish to connect to.
#  BITBAKE_OPTS = Set to "-c populate_sdk" or whatever other bitbake options
#                 you'd like to pass into the build.
#
###############################################################################

# Trace bash processing. Set -e so when a step fails, we fail the build
set -xeo pipefail

# Default variables
target=${target:-qemu}
distro=${distro:-ubuntu}
imgtag=${imgtag:-latest}
obmcdir=${obmcdir:-/tmp/openbmc}
sscdir=${sscdir:-${HOME}}
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
obmcext=${obmcext:-${WORKSPACE}/openbmc}
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
      wget

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

# Use the mounted repo cache to make an internal repo not mounted externally
cp -R ${obmcext} ${obmcdir}

# Go into the OpenBMC directory (the openbmc script will put us in a build subdir)
cd ${obmcdir}

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
EOF_CONF

# Kick off a build
bitbake ${BITBAKE_OPTS} obmc-phosphor-image

# Copy build directory of internal obmcdir into workspace directory
cp -a ${obmcdir}/build/. ${WORKSPACE}/build/

EOF_SCRIPT

chmod a+x ${WORKSPACE}/build.sh

# Determine if the build container will be launched with Docker or Kubernetes
if [[ "${launch}" == "" ]]; then

  # Give the Docker image a name based on the distro,tag,arch,and target
  imgname=${imgname:-openbmc/${distro}:${imgtag}-${target}-${ARCH}}

  # Build the Docker image
  docker build -t ${imgname} - <<< "${Dockerfile}"

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
  . ./kubernetes/kubernetes-launch.sh OpenBMC-build true true

else
  echo "Launch Parameter is invalid"
fi

# To maintain function of resources that used an older path, add a link
ln -sf ${WORKSPACE}/build/tmp/deploy ${WORKSPACE}/deploy

# Timestamp for build
echo "Build completed, $(date)"
