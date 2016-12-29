#!/bin/bash

# This build script is for running the Jenkins builds using docker.
#
# It expects a few variables which are part of Jenkins build job matrix:
#   ibm_container_volume = <the name of the volume to store build
#                           products in in IBM Containers>
#   container_registry = <the name of the IBM Containers registry to
#                         to keep Docker images in>
#   target = barreleye|palmetto|qemu
#   distro = fedora|ubuntu|ubuntu:14.04|ubuntu:16.04
#   BITBAKE_OPTS = <optional, set to "-c populate_sdk" or whatever other
#                   bitbake options you'd like to pass into the build>

# Trace bash processing. Set -e so when a step fails, we fail the build
set -xeo pipefail

# Default variables
target=${target:-qemu}
distro=${distro:-ubuntu}
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
  zaius)
    BITBAKE_CMD="TEMPLATECONF=meta-openbmc-machines/meta-openpower/meta-ingrasys/meta-zaius/conf source oe-init-build-env"
    ;;
  romulus)
    BITBAKE_CMD="TEMPLATECONF=meta-openbmc-machines/meta-openpower/meta-ibm/meta-romulus/conf source oe-init-build-env"
    ;;
  qemu)
    BITBAKE_CMD="source ~/workspace/openbmc/openbmc-env"
    ;;
  *)
    exit 1
    ;;
esac

# Write the build prep script
cat > build-prep.sh << EOF_SCRIPT
#!/bin/bash

set -xeo pipefail

# Give the baker user a place in the file mount
MOUNTPATH=/mnt/${ibm_container_volume}
usermod -aG root baker
chmod 775 \$MOUNTPATH
su -c "mkdir -p \${MOUNTPATH}/baker" -l baker
su -c "chmod 700 \${MOUNTPATH}/baker" -l baker
deluser baker root
chmod 755 \$MOUNTPATH

echo "Running build scrpt..."
su -c "bash /build.sh" -l baker >> /home/baker/build-log.txt

EOF_SCRIPT

chmod a+rx build-prep.sh

# Write the build script
cat > build.sh << EOF_SCRIPT
#!/bin/bash

set -xeo pipefail
whoami

# Clone the git repo
mkdir -p /home/baker/workspace
cd /home/baker/workspace

if [ -e ~/workspace/openbmc ] ; then
  cd /home/baker/workspace/openbmc;
  git pull;
else
  git clone https://github.com/openbmc/openbmc.git;
fi

cd /home/baker/workspace/openbmc

# Set up proxies
export ftp_proxy=${http_proxy}
export http_proxy=${http_proxy}
export https_proxy=${http_proxy}

mkdir -p /home/baker/workspace/bin

# Configure proxies for bitbake
if [[ -n "${http_proxy}" ]]; then

  cat > /home/baker/workspace/bin/git-proxy << \EOF_GIT
#!/bin/bash
# \$1 = hostname, \$2 = port
PROXY=${PROXY_HOST}
PROXY_PORT=${PROXY_PORT}
exec socat STDIO PROXY:\${PROXY}:\${1}:\${2},proxyport=\${PROXY_PORT}
EOF_GIT

  chmod a+x /home/baker/workspace/bin/git-proxy
  export PATH=~/workspace/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}
  git config core.gitProxy git-proxy

  mkdir -p /home/baker/.subversion

  cat > /home/baker/.subversion/servers << EOF_SVN
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
DL_DIR="/home/baker/bitbake_downloads"
SSTATE_DIR="/home/baker/bitbake_sharedstatecache"
USER_CLASSES += "buildstats"
INHERIT_remove = "uninative"
EOF_CONF

# Kick off a build
bitbake ${BITBAKE_OPTS} obmc-phosphor-image > /home/baker/bitbake-log.txt
cp /home/baker/bitbake-log.txt /mnt/${ibm_container_mount}/baker/bitbake-log.txt
cp /home/baker/build-log.txt /mnt/${ibm_container_mount}/baker/build-log.txt

rm -rf /mnt/${ibm_container_mount}/baker/images
cp -r /home/baker/workspace/openbmc/build/tmp/deploy/images* /mnt/${ibm_container_mount}/baker/images
cp /home/baker/build-log.txt /mnt/${ibm_container_mount}/baker

# when done
echo "Finished build"

EOF_SCRIPT

chmod a+rx build.sh

# Configure docker build
if [[ -n "${http_proxy}" ]]; then
  PROXY="RUN echo \"Acquire::http::Proxy \\"\"${http_proxy}/\\"\";\" > /etc/apt/apt.conf.d/000apt-cacher-ng-proxy"
fi

# Create the docker run script
# export PROXY_HOST=${http_proxy/#http*:\/\/}
# export PROXY_HOST=${PROXY_HOST/%:[0-9]*}
# export PROXY_PORT=${http_proxy/#http*:\/\/*:}

# Make the docker image
docker build -t obmc-build .
if [ $? -ne 0 ]; then
    echo "Docker build failed"
    exit
fi

# Push the docker image
docker tag obmc-build registry.ng.bluemix.net/${container_registry}/obmc-build
docker push registry.ng.bluemix.net/${container_registry}/obmc-build
if [ $? -ne 0 ]; then
    echo "Docker push failed"
    exit
fi

echo "Build submitted to IBM Container Service"

