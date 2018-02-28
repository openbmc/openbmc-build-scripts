#!/bin/bash -xe
###############################################################################
# Script used to create a gerrit instance that can run amd64 or ppc64le.
###############################################################################
# Build Variables:
#  g_vrsn             The version of the gerrit war file you wish to use
#                     Default: "2.14.6"
#  img_tag            The tag for the OpenJDK image used to build the Dockerfile
#                     Default: "/8-jdk"
#  g_user             Username tag the container will use to run Gerrit
#                     Default: "gerrit"
#  g_group            Group name tag the container will use to run Gerrit
#                     Default: "gerrit""
#  g_uid              Gerrit user ID the container will use to run Gerrit
#                     Default: "1000"
#  g_gif              Gerrit group ID the container will use to run Gerrit
#                     Default: "1000"
#  g_gerrit_dir       Directory used as the Gerrit Home in the container
#                     Default: "/var/gerrit"
#  http_port          The port used for gerrit UI
#                     Default: "8080"
#  ssh_port           The port used for gerrit ssh
#                     Default: "29418"
#  out_img            The name given to the Docker image when it is built
#                     Default: "openbmc/gerrit-master-${ARCH}:${GERRIT_VRSN}"
#
###############################################################################

set -xeo pipefail
ARCH=$(uname -m)

# Launch Variables
workspace=${workspace:-/tmp/gerrit-build-${RANDOM}}

# Dockerfile Variables
img_tag=${img_tag:-8-jdk}
g_vrsn=${g_vrsn:-2.14.6}
g_user=${g_user:-gerrit}
g_group=${g_group:-gerrit}
g_uid=${g_uid:-1000}
g_gid=${g_gid:-1000}
g_gerrit_dir=${g_gerrit_dir:-/var/gerrit}
http_port=${http_port:-8080}
ssh_port=${ssh_port:-29418}
out_img=${out_img:-openbmc/gerrit-master-${ARCH}:${g_vrsn}}

# Save the Gerrit.war URL to a variable and SHA if we care about verification
g_url=https://www.gerritcodereview.com/download/gerrit-${g_vrsn}.war

# Make or Clean WORKSPACE
if [[ -d ${workspace} ]]; then
  rm -rf ${workspace}/Dockerfile \
         ${workspace}/docker-gerrit
else
  mkdir -p ${workspace}
fi

# Determine the prefix of the Dockerfile's base image
case ${ARCH} in
  "ppc64le")
    docker_base="ppc64le/"
    ;;
  "x86_64")
    docker_base=""
    ;;
  *)
    echo "Unsupported system architecture(${ARCH}) found for docker image"
    exit 1
esac

# Move Into the WORKSPACE
cd ${workspace}

# Make the Dockerfile
###############################################################################
cat >> Dockerfile << EOF
FROM ${docker_base}openjdk:${img_tag}

RUN apt-get update && apt-get install -y git curl vim openssh-client sudo

# If you bind mount a volume from the host or a data container,
# ensure you use the same uid
RUN groupadd -g ${g_gid} ${g_group} && \
    useradd -d ${g_gerrit_dir} -u ${g_uid} -g ${g_gid} -m -s /bin/bash ${g_user}

USER ${g_user}

# download and install gerrit
RUN cd /tmp && wget ${g_url} && \
    mkdir ${g_gerrit_dir}/bin/ && \
    mv gerrit-${g_vrsn}.war  ${g_gerrit_dir}/bin/gerrit.war && \
    java -jar ${g_gerrit_dir}/bin/gerrit.war init --batch --install-all-plugins -d ${g_gerrit_dir}

# Allow incoming traffic
EXPOSE 29418 8080

CMD ${g_gerrit_dir}/bin/gerrit.sh start && tail -f ${g_gerrit_dir}/logs/error_log
EOF
###############################################################################

# Build the image
docker build -t ${out_img} .
