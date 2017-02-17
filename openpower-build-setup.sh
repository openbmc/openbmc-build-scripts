#/bin/bash

# This build script is for running the Jenkins builds using docker.
#
# It expects a few variables which are part of Jenkins build job matrix:
#   target = palmetto|qemu|habanero|firestone|garrison
#   distro = ubuntu|fedora|debian|centos*
#   WORKSPACE = random number
#       *Not available for ppcle64

# Trace bash processing
set -x

# Default variables
target=${target:-palmetto}
distro=${distro:-ubuntu}
WORKSPACE=${WORKSPACE:-${HOME}/opbuildtest}
http_proxy=${http_proxy:-}

# Timestamp for job
echo "Build started, $(date)"

# if there is no open-power directory clone in master
if [ ! -e ${WORKSPACE}/op-build ]; then
        echo "Clone in openpower master to ${WORKSPACE}/op-build"
        git clone --recursive https://github.com/open-power/op-build ${WORKSPACE}/op-build
fi

# Determine our architecture, ppc64le or the other one
if [ $(uname -m) == "ppc64le" ]; then
    DOCKER_BASE="ppc64le/"
else
    DOCKER_BASE=""
fi

# Configure docker build
if [[ "${distro}" == fedora ]];then

  Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}fedora:latest

RUN dnf --refresh repolist && dnf install -y \
        bc \
        bison \
        bzip2 \
        cpio \
        cscope \
        ctags \
        expat-devel \
        findutils \
        flex \
        gcc-c++ \
        git \
        libxml2-devel \
	libxslt-devel \
        ncurses-devel \
        patch \
        perl \
        perl-bignum \
        "perl(Digest::SHA1)" \
        "perl(Env)" \
        "perl(Fatal)" \
        "perl(ExtUtils::MakeMaker)" \
        "perl(Thread::Queue)" \
        "perl(XML::SAX)" \
        "perl(XML::Simple)" \
        "perl(YAML)" \
        "perl(XML::LibXML)" \
        python \
        tar \
        unzip \
        vim \
        wget \
        which \
        zlib-devel \
        zlib-static

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

USER ${USER}
ENV HOME ${HOME}
RUN /bin/bash
EOF
)

elif [[ "${distro}" == ubuntu ]]; then

  Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}ubuntu:latest

ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update && apt-get install -yy \
        bc \
        bison \
        build-essential \
        cscope \
        cpio \
        ctags \
        flex \
        g++ \
        git \
        libexpat-dev \
        libz-dev \
        libxml-sax-perl \
        libxml-simple-perl \
        libxml2-dev \
        libxml2-utils \
        language-pack-en \
        python \
        texinfo \
        unzip \
        vim-common \
        wget\
        xsltproc

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

USER ${USER}
ENV HOME ${HOME}
RUN /bin/bash
EOF
)

elif [[ "${distro}" == debian ]];then

  Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}debian:latest

ENV DEBIAN_FRONTEND noninteractive
# Add en_US.utf8 locale
RUN apt-get update && apt-get install -y locales && rm -rf /var/lib/apt/lists/* \
    && localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
ENV LANG en_US.utf8

RUN apt-get update && apt-get install -yy \
        apt-utils \
        bc \
        bison \
        build-essential \
        cpio \
        cscope \
        ctags \
        flex \
        g++ \
        git \
        libexpat-dev \
        libxml-simple-perl \
        libxml-sax-perl \
        libxml2-dev \
        libxml2-utils \
        libz-dev \
        python \
        texinfo \
        unzip \
        vim \
        wget \
        xsltproc

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

USER ${USER}
ENV HOME ${HOME}
RUN /bin/bash
EOF
)

elif [[ "${distro}" == centos ]] && [[ -z "${DOCKER_BASE}" ]];then

  Dockerfile=$(cat << EOF
FROM centos:latest

RUN     yum makecache \
        && yum update -y \
        && yum install -y \
        bc \
        bison \
        bzip2 \
        cpio \
        cscope \
        ctags \
        expat-devel \
        findutils \
        flex \
        gcc-c++ \
        git \
        libxml2-devel \
	libxslt-devel \
        ncurses-devel \
        patch \
        perl \
        perl-bignum \
        "perl(Digest::SHA1)" \
        "perl(Env)" \
        "perl(Fatal)" \
        "perl(ExtUtils::MakeMaker)" \
        "perl(Thread::Queue)" \
        "perl(XML::SAX)" \
        "perl(XML::Simple)" \
        "perl(YAML)" \
        "perl(XML::LibXML)" \
        python \
        tar \
        unzip \
        vim \
        wget \
        which \
        zlib-devel \
        zlib-static \
        && yum clean all

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}

USER ${USER}
ENV HOME ${HOME}
RUN /bin/bash
EOF
)

else
  echo "Error, Distro incompatible verify name and docker_base."
  exit 1
fi

# Build the docker container
docker build -t op-build/${distro} - <<< "${Dockerfile}"
if [[ "$?" -ne 0 ]]; then
  echo "Failed to build docker container."
  exit 1
fi

mkdir -p ${WORKSPACE}

cat > "${WORKSPACE}"/build.sh << EOF_SCRIPT
#!/bin/bash

set -x

# This ensures that the alias set in op-build-env is
# avalaible in this script
shopt -s expand_aliases

cd ${WORKSPACE}/op-build

# Source our build env
. op-build-env

# Configure
op-build ${target}_defconfig

# Kick off a build
op-build

EOF_SCRIPT

chmod a+x ${WORKSPACE}/build.sh

# Run the docker container, execute the build script we just built
docker run --net=host --rm=true -e WORKSPACE=${WORKSPACE} --user="${USER}" \
  -w "${HOME}" -v "${HOME}":"${HOME}" -t op-build/${distro} ${WORKSPACE}/build.sh

# Create link to images for archiving
ln -sf ${WORKSPACE}/op-build/output/images ${WORKSPACE}/images

# Timestamp for build
echo "Build completed, $(date)"
