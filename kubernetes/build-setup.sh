#!/bin/bash
###############################################################################
#
# This build script is for running the OpenBMC builds using Kubernetes to
# create the build containers as Kubernetes jobs
#
###############################################################################
#
# Requirements:
#  - Docker login credentials defined inside ~/.docker/config.json
#  - Kubectl installed and configured on machine running the script
#  - Access to a Kubernetes Cluster using v1.5.2 or newer
#  - NFS directory to which user running script has RWX access
#  - Persistent Volume and Claim created and mounted to NFS directory
#  - Image pull secret exists if using a private image repository
#
###############################################################################
#
# Variables used for Jenkins build job matrix:
#  target       = barreleye|palmetto|witherspoon|firestone|garrison|evb-ast2500
#                 zaius|romulus|qemu
#  distro       = fedora|ubuntu|
#  imgtag       = varies by distro, latest;16.04|14.04|trusty|xenial; 23|24|25
#  obmcdir      = path of the openbmc directory, where the build occurs cannot
#                 be placed on external storage
#  WORKSPACE    = path of the workspace directory where some intermediate files
#                 and the images will be saved to
#  BITBAKE_OPTS = optional, set to "-c populate_sdk" or whatever other bitbake
#                 options you'd like to pass into the build
#
# Variables used to create Kubernetes Job:
#  namespace    = The namespace to be used within the Kubernetes cluster
#  pvcname      = name of the persistent volume claim (PVC)
#  mountpath    = the path onto which the PVC will be mounted to within the
#                 build container
#  sscdir       = path of the shared-state cache directory
#  registry     = the image registry used to push and pull images
#  imgplsec     = the image pull secret used to access the image registry
#  timeout      = the amount of time in seconds that the build will wait for
#                 the pod to start running on the cluster
#
###############################################################################

# Trace bash processing. Set -e so when a step fails, we fail the build
set -xeo pipefail

# Default variables
target=${target:-qemu}
distro=${distro:-ubuntu}
imgtag=${imgtag:-latest}
obmcdir=${obmcdir:-openbmc}
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
http_proxy=${http_proxy:-}
PROXY=""

# Kubernetes variables
namespace=${namespace:-openbmc}
pvcname=${pvcname:-work-volume}
mountpath=${mountpath:-/home}
sscdir=${sscdir:-/home/sstate-cache}
registry=${registry:-master.cfc:8500/openbmc/}
imgplsec=${imgplsec:-regkey}
timeout=${timeout:-25}

# Timestamp for job
echo "Build started, $(date)"

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

# Determine the build target and set the bitbake command
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

  RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} jenkins
  RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} jenkins

  RUN mkdir -p ${WORKSPACE}
  RUN mkdir ${obmcdir}
  RUN chown jenkins:jenkins ${obmcdir}
  USER jenkins
  RUN git clone https://github.com/openbmc/openbmc ${obmcdir}

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

  # Set Locales
  RUN locale-gen en_US.UTF-8
  ENV LANG en_US.UTF-8
  ENV LANGUAGE en_US:en
  ENV LC_ALL en_US.UTF-8

  RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} jenkins
  RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} jenkins

  RUN mkdir -p ${WORKSPACE}
  RUN mkdir ${obmcdir}
  RUN chown jenkins:jenkins ${obmcdir}
  USER jenkins
  RUN git clone https://github.com/openbmc/openbmc ${obmcdir}

  ENV HOME ${HOME}
  RUN /bin/bash
  EOF
  )
fi

# Build the image and push to registry
docker build -t ${registry}${distro}:${imgtag} - <<< "${Dockerfile}"
docker push ${registry}${distro}:${imgtag}

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
DL_DIR="${sscdir}/bitbake_downloads"
SSTATE_DIR="${ssdir}/bitbake_sharedstatecache"
USER_CLASSES += "buildstats"
INHERIT_remove = "uninative"
EOF_CONF

# Kick off a build
bitbake ${BITBAKE_OPTS} obmc-phosphor-image

# copy the artifacts to NFS
cp -R ${obmcdir}/build/tmp/deploy/images ${WORKSPACE}/images/

EOF_SCRIPT

chmod a+x ${WORKSPACE}/build.sh

# Create the Kubernetes job in YAML format
  Job=$(cat << EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: openbmc-${target}
  namespace: ${namespace}
  labels:
    app: openbmc
    stage: build
spec:
  template:
    metadata:
      labels:
        target: ${target}
    spec:
      nodeSelector:
        worker: "true"
        arch: ${ARCH}
      volumes:
      - persistentVolumeClaim:
          claimName: ${pvcname}
        name: home
      restartPolicy: Never
      hostNetwork: True
      containers:
      - image: ${registry}${distro}:${tag}
        name: builder
        command: ["${WORKSPACE}/build.sh"]
        args: []
        workingDir: /home/jenkins
        env:
        - name: WORKSPACE
          value: ${WORKSPACE}
        securityContext:
          capabilities:
            add:
            - SYS_ADMIN
        volumeMounts:
        - name: home
          mountPath: ${mountpath}
      imagePullSecrets:
      - name: ${imgplsec}
EOF
)

# Create the Kubernetes Job
kubectl create -f - <<< "${Job}"

# Save its name
POD=$(kubectl get pods | grep ${target} | cut -d " " -f1)

# Wait for Pod to be running before tailing log file
while [ -z "$(kubectl describe pod ${POD}| grep Status: | grep Running)" ]; do
  if [ ${timeout} -lt 0 ];then
    kubectl delete -f - <<< "${Job}"
    echo "Timeout Occured: Job failed to start running in time"
    exit 1
  else
    sleep 1
    let timeout-=1
  fi
done

# Once pod is running track logs
kubectl logs -f ${POD}

# When job is completed wipe the job
kubectl delete -f - <<< "${Job}"

# Timestamp for build
echo "Build completed, $(date)"