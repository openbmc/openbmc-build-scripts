#!/bin/bash

# This build script is for running the Jenkins builds using docker.
#
# It expects a few variables which are part of Jenkins build job matrix:
#   target = barreleye|palmetto|qemu
#   distro = fedora|ubuntu
#   WORKSPACE = 

# Trace bash processing
set -x

# Default variables
target=${target:-qemu}
distro=${distro:-ubuntu}
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
http_proxy=${http_proxy:-}

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
FROM fedora:latest

${PROXY}

RUN dnf --refresh upgrade -y
RUN dnf install -y git subversion gcc gcc-c++ make perl-Thread-Queue perl-Data-Dumper diffstat texinfo \
chrpath wget SDL-devel patch bzip2 tar cpio findutils socat which python-devel perl-bignum

RUN groupadd -g ${GROUPS} ${USER} && useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

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
FROM ubuntu:latest

${PROXY}

RUN echo $(date +%s) && apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential git subversion diffstat texinfo \
  chrpath wget libthread-queue-any-perl libdata-dumper-simple-perl python libsdl1.2-dev gawk socat debianutils

RUN groupadd -g ${GROUPS} ${USER} && useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

USER ${USER}
ENV HOME ${HOME}
RUN /bin/bash
EOF
)
fi

# Build the docker container
docker build -t openbmc/${distro} - <<< "${Dockerfile}"
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

# Go into the openbmc directory (the openbmc script will put us in a build subdir)
cd openbmc

# Set up proxies
export ftp_proxy=${http_proxy}
export http_proxy=${http_proxy}
export https_proxy=${http_proxy}

mkdir -p ${WORKSPACE}/bin

# Configure proxies for bitbake
if [[ -n "${http_proxy}" ]]; then

  cat > ${WORKSPACE}/bin/git-proxy << EOF_GIT
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
BB_NUMBER_THREADS = "$(($(nproc) / 4))"
PARALLEL_MAKE = "-j$(($(nproc) / 4))"
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

