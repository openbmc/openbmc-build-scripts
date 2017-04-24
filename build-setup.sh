#!/bin/bash

# This build script is for running the Jenkins builds using Docker or Kubernetes.
#
# It expects a few variables which are part of Jenkins build job matrix:
#   target = barreleye|palmetto|qemu
#   distro = fedora|ubuntu
#   imgtag = tag of the Ubuntu or Fedora image to use (default latest)
#   obmcdir = <name of OpenBMC src dir> (default /tmp/openbmc)
#   sscdir = directory that will be used for shared state cache
#   WORKSPACE = <location of base OpenBMC/OpenBMC repo>
#   BITBAKE_OPTS = <optional, set to "-c populate_sdk" or whatever other
#                   BitBake options you'd like to pass into the build>
#
# There are some optional variables that are related to launching the build
#   launch = job|pod, what way the build container will be launched. If left
#            blank launches user docker run, job or pod will launch the
#            appropriate kind to kubernetes via kubernetes-launch.sh
#   imgname = defaults to a relatively long but descriptive name, can be
#             changed or passed to give a specific name to created image

# Trace bash processing. Set -e so when a step fails, we fail the build
set -xeo pipefail

# Default variables
target=${target:-qemu}
distro=${distro:-ubuntu}
imgtag=${imgtag:-latest}
ocache=${ocache:-/home/openbmc}
obmcdir=${obmcdir:-/tmp/openbmc}
sscdir=${sscdir:-${HOME}}
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
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

# If the ocache directory doesn't exist clone it in, ocache will be used as a cache for git clones
if [ ! -d ${ocache} ]; then
  echo "Clone in openbmc master to ${ocache} to act as cache for future builds"
  git clone https://github.com/openbmc/openbmc ${ocache}
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

# Create the Docker run script
export PROXY_HOST=${http_proxy/#http*:\/\/}
export PROXY_HOST=${PROXY_HOST/%:[0-9]*}
export PROXY_PORT=${http_proxy/#http*:\/\/*:}

mkdir -p ${WORKSPACE}

cat > "${WORKSPACE}"/build.sh << EOF_SCRIPT
#!/bin/bash

set -xeo pipefail

# Use the mounted repo cache to make an internal repo not mounted externally
git clone --reference ${ocache} --dissociate https://github.com/openbmc/openbmc ${obmcdir}

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

# Copy images out of internal obmcdir into workspace directory
cp -R ${obmcdir}/build/tmp/deploy/images ${WORKSPACE}/images/

EOF_SCRIPT

chmod a+x ${WORKSPACE}/build.sh

# Determine if the build container will be launched with Docker or Kubernetes
if [[ "${launch}" == "" ]]; then

  # Give the Docker image a name based on the distro,tag,arch,and target
  imgname=${imgname:-openbmc/${distro}:${imgtag}-${target}-${ARCH}}

  # Build the Docker image
  docker build -t ${imgname} - <<< "${Dockerfile}"

  # If ocache or sscdir are ${HOME} or a subdirectory they will not be mounted
  mountocache="-v ""${ocache}"":""${ocache}"" "
  mountsscdir="-v ""${sscdir}"":""${sscdir}"" "
  if [[ "${ocache}" = "${HOME}/*" || "${ocache}" = "${HOME}" ]];then
    mountocache=""
  fi
  if [[ "${sscdir}" = "${HOME}/*" || "${sscdir}" = "${HOME}" ]];then
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
  ${mountocache} \
  ${mountsscdir} \
  -t ${imgname} \
  ${WORKSPACE}/build.sh

elif [[ "${launch}" == "job" || "${launch}" == "pod" ]]; then

  # Source and run the helper script to launch the pod or job
  . kubernetes/kubernetes-launch.sh

else
  echo "Launch Parameter is invalid"
fi

# Timestamp for build
echo "Build completed, $(date)"
