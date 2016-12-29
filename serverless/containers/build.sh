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
export ftp_proxy=
export http_proxy=
export https_proxy=

mkdir -p /home/baker/workspace/bin

# Configure proxies for bitbake
if [[ -n "" ]]; then

  cat > /home/baker/workspace/bin/git-proxy << \EOF_GIT
#!/bin/bash
# $1 = hostname, $2 = port
PROXY=
PROXY_PORT=
exec socat STDIO PROXY:${PROXY}:${1}:${2},proxyport=${PROXY_PORT}
EOF_GIT

  chmod a+x /home/baker/workspace/bin/git-proxy
  export PATH=~/workspace/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/lib64/qt-3.3/bin:/usr/local/bin:/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/opt/ibm/cmvc/bin:/afs/austin.ibm.com/projects/esw/bin:/usr/ode/bin:/usr/lpp/cmvc/bin:/gsa/ausgsa/home/c/p/cphofer/bin
  git config core.gitProxy git-proxy

  mkdir -p /home/baker/.subversion

  cat > /home/baker/.subversion/servers << EOF_SVN
[global]
http-proxy-host = 
http-proxy-port = 
EOF_SVN
fi

# Source our build env
source ~/workspace/openbmc/openbmc-env

# Custom bitbake config settings
cat >> conf/local.conf << EOF_CONF
BB_NUMBER_THREADS = "24"
PARALLEL_MAKE = "-j24"
INHERIT += "rm_work"
BB_GENERATE_MIRROR_TARBALLS = "1"
DL_DIR="/home/baker/bitbake_downloads"
SSTATE_DIR="/home/baker/bitbake_sharedstatecache"
USER_CLASSES += "buildstats"
INHERIT_remove = "uninative"
EOF_CONF

# Kick off a build
bitbake  obmc-phosphor-image > /home/baker/bitbake-log.txt
cp /home/baker/bitbake-log.txt /mnt/cphofer/baker/bitbake-log.txt
cp /home/baker/build-log.txt /mnt/cphofer/baker/build-log.txt

rm -rf /mnt/cphofer/baker/images
cp -r /home/baker/workspace/openbmc/build/tmp/deploy/images* /mnt/cphofer/baker/images
cp /home/baker/build-log.txt /mnt/cphofer/baker

# when done
echo "Finished build"

