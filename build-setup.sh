#!/bin/bash
###############################################################################
#
# This build script is for running the OpenBMC builds as Docker containers.
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
#  num_cpu            Number of cpu's to give bitbake, default is total amount
#                     in system
#  UBUNTU_MIRROR      [optional] The URL of a mirror of Ubuntu to override the
#                     default ones in /etc/apt/sources.list
#                     default is empty, and no mirror is used.
#  ENV_LOCAL_CONF     [optional] The environment variables to inject into the
#                     build, which will be written into local.conf.
#                     default is empty.
#  CONTAINER_ONLY     Set to "true" if you only want to build the docker
#                     container. The bitbake will not occur in this case.
#  DOCKER_REG:        <optional, the URL of a docker registry to utilize
#                     instead of our default (public.ecr.aws/ubuntu)
#                     (ex. docker.io or public.ecr.aws/docker/library)
#
# Docker Image Build Variables:
#  BITBAKE_OPTS       Set to "-c populate_sdk" or whatever other BitBake options
#                     you'd like to pass into the build.
#                     Default: "", no options set
#  build_dir          Path where the actual BitBake build occurs inside the
#                     container, path cannot be located on network storage.
#                     Default: "$WORKSPACE/build"
#  distro             The distro used as the base image for the build image:
#                     fedora|ubuntu. Note that if you chose fedora, you will
#                     need to also update DOCKER_REG to a supported fedora reg.
#                     Default: "ubuntu"
#  img_name           The name given to the target build's docker image.
#                     Default: "openbmc/${distro}:${imgtag}-${target}-${ARCH}"
#  img_tag            The base docker image distro tag:
#                     ubuntu: latest|16.04|14.04|trusty|xenial
#                     fedora: 23|24|25
#                     Default: "latest"
#  target             The target we aim to build.  Any system supported by
#                     the openbmc/openbmc `setup` script is an option.
#                     repotest is a target to specifically run the CI checks
#                     Default: "qemuarm"
#  no_tar             Set to true if you do not want the debug tar built
#                     Default: "false"
#  nice_priority      Set nice priority for bitbake command.
#                     Nice:
#                       Run with an adjusted niceness, which affects process
#                       scheduling. Nice values range from -20 (most favorable
#                       to the process) to 19 (least favorable to the process).
#                     Default: "", nice is not used if nice_priority is not set
#
# Deployment Variables:
#  obmc_dir           Path of the OpenBMC repo directory used as a reference
#                     for the build inside the container.
#                     Default: "${WORKSPACE}/openbmc"
#  ssc_dir            Path of the OpenBMC shared directory that contains the
#                     downloads dir and the sstate dir.
#                     Default: "${HOME}"
#  xtrct_small_copy_dir
#                     Directory within build_dir that should be copied to
#                     xtrct_path. The directory and all parents up to, but not
#                     including, build_dir will be copied. For example, if
#                     build_dir is set to "/tmp/openbmc" and this is set to
#                     "build/tmp", the directory at xtrct_path will have the
#                     following directory structure:
#                     xtrct_path
#                      | - build
#                        | - tmp
#                          ...
#                     Can also be set to the empty string to copy the entire
#                     contents of build_dir to xtrct_path.
#                     Default: "deploy/images".
#
###############################################################################
# Trace bash processing. Set -e so when a step fails, we fail the build
set -xeo pipefail

# Script Variables:
build_scripts_dir=${build_scripts_dir:-"$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}
http_proxy=${http_proxy:-}
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
num_cpu=${num_cpu:-$(nproc)}
UBUNTU_MIRROR=${UBUNTU_MIRROR:-""}
ENV_LOCAL_CONF=${ENV_LOCAL_CONF:-""}
container_only=${CONTAINER_ONLY:-false}
docker_reg=${DOCKER_REG:-"public.ecr.aws/ubuntu"}

# Docker Image Build Variables:
build_dir=${build_dir:-${WORKSPACE}/build}
distro=${distro:-ubuntu}
img_tag=${img_tag:-latest}
target=${target:-qemuarm}
no_tar=${no_tar:-false}
nice_priority=${nice_priority:-}

# Deployment variables
obmc_dir=${obmc_dir:-${WORKSPACE}/openbmc}
ssc_dir=${ssc_dir:-${HOME}}
xtrct_small_copy_dir=${xtrct_small_copy_dir:-deploy/images}
xtrct_path="${obmc_dir}/build/tmp"
xtrct_copy_timeout="300"

bitbake_target="obmc-phosphor-image"
PROXY=""

MIRROR=""
if [[ -n "${UBUNTU_MIRROR}" ]]; then
    MIRROR="RUN echo \"deb ${UBUNTU_MIRROR} \$(. /etc/os-release && echo \$VERSION_CODENAME) main restricted universe multiverse\" > /etc/apt/sources.list && \
        echo \"deb ${UBUNTU_MIRROR} \$(. /etc/os-release && echo \$VERSION_CODENAME)-updates main restricted universe multiverse\" >> /etc/apt/sources.list && \
        echo \"deb ${UBUNTU_MIRROR} \$(. /etc/os-release && echo \$VERSION_CODENAME)-security main restricted universe multiverse\" >> /etc/apt/sources.list && \
        echo \"deb ${UBUNTU_MIRROR} \$(. /etc/os-release && echo \$VERSION_CODENAME)-proposed main restricted universe multiverse\" >> /etc/apt/sources.list && \
        echo \"deb ${UBUNTU_MIRROR} \$(. /etc/os-release && echo \$VERSION_CODENAME)-backports main restricted universe multiverse\" >> /etc/apt/sources.list"
fi

# Timestamp for job
echo "Build started, $(date)"

# If the obmc_dir directory doesn't exist clone it in
if [ ! -d "${obmc_dir}" ]; then
    echo "Clone in openbmc master to ${obmc_dir}"
    git clone https://github.com/openbmc/openbmc "${obmc_dir}"
fi

if [[ "$target" = repotest ]]; then
    DOCKER_IMAGE_NAME=$(./scripts/build-unit-test-docker)
    docker run --cap-add=sys_admin --rm=true \
        --network host \
        --privileged=true \
        -u "$USER" \
        -w "${obmc_dir}" -v "${obmc_dir}:${obmc_dir}" \
        -t "${DOCKER_IMAGE_NAME}" \
        "${obmc_dir}"/meta-phosphor/scripts/run-repotest
    exit
fi

# Make and chown the xtrct_path directory to avoid permission errors
if [ ! -d "${xtrct_path}" ]; then
    mkdir -p "${xtrct_path}"
fi
chown "${UID}:${GROUPS[0]}" "${xtrct_path}"

# Perform overrides for specific machines as required.
DISTRO=${DISTRO:-}

# Set build target and BitBake command
MACHINE="${target}"
BITBAKE_CMD="source ./setup ${MACHINE} ${build_dir}"

# Configure Docker build
if [[ "${distro}" == fedora ]];then

    if [[ -n "${http_proxy}" ]]; then
        PROXY="RUN echo \"proxy=${http_proxy}\" >> /etc/dnf/dnf.conf"
    fi

    Dockerfile=$(cat << EOF
  FROM ${docker_reg}/${distro}:${img_tag}

  ${PROXY}

  RUN dnf --refresh install -y \
      bzip2 \
      chrpath \
      cpio \
      diffstat \
      file \
      findutils \
      gcc \
      gcc-c++ \
      git \
      lz4 \
      make \
      patch \
      perl-bignum \
      perl-Data-Dumper \
      perl-Thread-Queue \
      python3-devel \
      SDL-devel \
      socat \
      subversion \
      tar \
      texinfo \
      wget \
      which \
      file \
      hostname \
      rpcgen \
      glibc-langpack-en \
      glibc-locale-source \
      zstd

  # Set the locale
  ENV LANG=en_US.utf8
  RUN localedef -f UTF-8 -i en_US en_US.UTF-8

  RUN grep -q ${GROUPS[0]} /etc/group || groupadd -g ${GROUPS[0]} ${USER}
  RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS[0]} ${USER}

  USER ${USER}
  ENV HOME ${HOME}
EOF
    )

elif [[ "${distro}" == ubuntu ]]; then

    if [[ -n "${http_proxy}" ]]; then
        PROXY="RUN echo \"Acquire::http::Proxy \\"\"${http_proxy}/\\"\";\" > /etc/apt/apt.conf.d/000apt-cacher-ng-proxy"
    fi

    Dockerfile=$(cat << EOF
  FROM ${docker_reg}/${distro}:${img_tag}

  ${PROXY}
  ${MIRROR}

  ENV DEBIAN_FRONTEND noninteractive

  RUN apt-get update && apt-get install -yy \
      build-essential \
      chrpath \
      cpio \
      debianutils \
      diffstat \
      file \
      gawk \
      git \
      iputils-ping \
      libdata-dumper-simple-perl \
      liblz4-tool \
      libsdl1.2-dev \
      libthread-queue-any-perl \
      locales \
      python3 \
      socat \
      subversion \
      texinfo \
      vim \
      wget \
      zstd

  # Set the locale
  RUN locale-gen en_US.UTF-8
  ENV LANG en_US.UTF-8
  ENV LANGUAGE en_US:en
  ENV LC_ALL en_US.UTF-8

  # Latest Ubuntu added a default user (ubuntu), which takes 1000 UID.
  # If the user calling this build script happens to also have a UID of 1000
  # then the container no longer will work. Delete the new ubuntu user
  # so there is no conflict
  RUN if id ubuntu > /dev/null 2>&1; then userdel -r ubuntu > /dev/null 2>&1; fi
  RUN grep -q ${GROUPS[0]} /etc/group || groupadd -g ${GROUPS[0]} ${USER}
  RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS[0]} ${USER}

  USER ${USER}
  ENV HOME ${HOME}
EOF
    )
fi

# Create the Docker run script
export PROXY_HOST=${http_proxy/#http*:\/\/}
export PROXY_HOST=${PROXY_HOST/%:[0-9]*}
export PROXY_PORT=${http_proxy/#http*:\/\/*:}

mkdir -p "${WORKSPACE}"

# Determine command for bitbake image build
if [ "$no_tar" = "false" ]; then
    bitbake_target="${bitbake_target} obmc-phosphor-debug-tarball"
fi

cat > "${WORKSPACE}"/build.sh << EOF_SCRIPT
#!/bin/bash

set -xeo pipefail

# Go into the OpenBMC directory, the build will handle changing directories
cd ${obmc_dir}

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

  lock=${HOME}/build-setup.lock
  flock \${lock} git config --global core.gitProxy ${WORKSPACE}/bin/git-proxy
  flock \${lock} git config --global http.proxy ${http_proxy}

  flock \${lock} mkdir -p ~/.subversion
  flock \${lock} cat > ~/.subversion/servers << EOF_SVN
  [global]
  http-proxy-host = ${PROXY_HOST}
  http-proxy-port = ${PROXY_PORT}
EOF_SVN

  flock \${lock} cat > ~/.wgetrc << EOF_WGETRC
  https_proxy = ${http_proxy}
  http_proxy = ${http_proxy}
  use_proxy = on
EOF_WGETRC

  flock \${lock} cat > ~/.curlrc << EOF_CURLRC
  proxy = ${PROXY_HOST}:${PROXY_PORT}
EOF_CURLRC
fi

# Source our build env
${BITBAKE_CMD}

if [[ -z "${MACHINE}" ]]; then
  echo "MACHINE is not configured for ${target}"
  exit 1
fi

export MACHINE="${MACHINE}"
if [[ -z "${DISTRO}" ]]; then
  echo "DISTRO is not configured for ${target} so will use default"
  unset DISTRO
else
  export DISTRO="${DISTRO}"
fi

# bitbake requires SDKMACHINE be x86
export SDKMACHINE=x86_64

# Custom BitBake config settings
cat >> conf/local.conf << EOF_CONF
BB_NUMBER_THREADS = "$num_cpu"
PARALLEL_MAKE = "-j$num_cpu"
INHERIT += "rm_work"
BB_GENERATE_MIRROR_TARBALLS = "1"
DL_DIR="${ssc_dir}/bitbake_downloads"
SSTATE_DIR="${ssc_dir}/bitbake_sharedstatecache"
USER_CLASSES += "buildstats"
INHERIT:remove = "uninative"
TMPDIR="${build_dir}"
${ENV_LOCAL_CONF}
EOF_CONF

# Kick off a build
if [[ -n "${nice_priority}" ]]; then
    nice -${nice_priority} bitbake -k ${BITBAKE_OPTS} ${bitbake_target}
else
    bitbake -k ${BITBAKE_OPTS} ${bitbake_target}
fi

# Copy internal build directory into xtrct_path directory
if [[ ${xtrct_small_copy_dir} ]]; then
  mkdir -p ${xtrct_path}/${xtrct_small_copy_dir}
  timeout ${xtrct_copy_timeout} cp -r ${build_dir}/${xtrct_small_copy_dir}/* ${xtrct_path}/${xtrct_small_copy_dir}
else
  timeout ${xtrct_copy_timeout} cp -r ${build_dir}/* ${xtrct_path}
fi

if [[ 0 -ne $? ]]; then
  echo "Received a non-zero exit code from timeout"
  exit 1
fi

EOF_SCRIPT

chmod a+x "${WORKSPACE}/build.sh"

# Give the Docker image a name based on the distro,tag,arch,and target
img_name=${img_name:-openbmc/${distro}:${img_tag}-${target}-${ARCH}}

# Ensure appropriate docker build output to see progress and identify
# any issues
export BUILDKIT_PROGRESS=plain

# Build the Docker image
docker build --network=host -t "${img_name}" - <<< "${Dockerfile}"

if [[ "$container_only" = "true" ]]; then
    exit 0
fi

# If obmc_dir or ssc_dir are ${HOME} or a subdirectory they will not be mounted
mount_obmc_dir="-v ""${obmc_dir}"":""${obmc_dir}"" "
mount_ssc_dir="-v ""${ssc_dir}"":""${ssc_dir}"" "
mount_workspace_dir="-v ""${WORKSPACE}"":""${WORKSPACE}"" "
if [[ "${obmc_dir}" = "${HOME}/"* || "${obmc_dir}" = "${HOME}" ]];then
    mount_obmc_dir=""
fi
if [[ "${ssc_dir}" = "${HOME}/"* || "${ssc_dir}" = "${HOME}" ]];then
    mount_ssc_dir=""
fi
if [[ "${WORKSPACE}" = "${HOME}/"* || "${WORKSPACE}" = "${HOME}" ]];then
    mount_workspace_dir=""
fi

# If we are building on a podman based machine, need to have this set in
# the env to allow the home mount to work (no impact on non-podman systems)
export PODMAN_USERNS="keep-id"

# Run the Docker container, execute the build.sh script
# shellcheck disable=SC2086 # mount commands word-split purposefully
docker run \
    --cap-add=sys_admin \
    --cap-add=sys_nice \
    --net=host \
    --rm=true \
    -e WORKSPACE="${WORKSPACE}" \
    -w "${HOME}" \
    -v "${HOME}:${HOME}" \
    ${mount_obmc_dir} \
    ${mount_ssc_dir} \
    ${mount_workspace_dir} \
    "${img_name}" \
    "${WORKSPACE}/build.sh"

# To maintain function of resources that used an older path, add a link
ln -sf "${xtrct_path}/deploy" "${WORKSPACE}/deploy"

# Timestamp for build
echo "Build completed, $(date)"
