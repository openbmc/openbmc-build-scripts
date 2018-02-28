#!/bin/bash -xe
###############################################################################
# Script used to create a gerrit instance that can run amd64 or ppc64le.
#
# To persist your gerrit data, it's reccomended you mount these folders:
#  /var/gerrit/etc
#  /var/gerrit/git
#  /var/gerrit/index
#  /var/gerrit/cache
#  /var/gerrit/db
#  /var/lib/postgresql
###############################################################################
# Build Variables:
#  g_vrsn             The version of the gerrit war file you wish to use
#                     Default: "2.15.2"
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
# Use slim version as workaround to
#  https://github.com/docker-library/openjdk/issues/145
g_vrsn=${g_vrsn:-2.15.2}
g_user=${g_user:-gerrit}
g_group=${g_group:-gerrit}
g_uid=${g_uid:-1000}
g_gid=${g_gid:-1000}
g_gerrit_dir=${g_gerrit_dir:-/var/gerrit}
http_port=${http_port:-8080}
ssh_port=${ssh_port:-29418}
out_img=${out_img:-openbmc/gerrit-master-${ARCH}:${g_vrsn}}

# Save the Gerrit.war URL to a variable and SHA if we care about verification
g_url=https://gerrit-releases.storage.googleapis.com/gerrit-${g_vrsn}.war

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
FROM ${docker_base}ubuntu:17.10

RUN apt-get update && apt-get install -y git curl vim openssh-client \
                                         sudo postgresql postgresql-contrib \
                                         maven wget openjdk-8-jdk

# If you bind mount a volume from the host or a data container,
# ensure you use the same uid
RUN groupadd -g ${g_gid} ${g_group} && \
    useradd -d ${g_gerrit_dir} -u ${g_uid} -g ${g_gid} -m -s /bin/bash ${g_user}

# postgres database setup
RUN service postgresql start && \
    sudo -i -u postgres psql -c "CREATE USER ${g_user} with SUPERUSER password '0penBmc'" &&  \
    sudo -i -u postgres psql -c "CREATE DATABASE gerrit WITH OWNER = ${g_user}"

USER ${g_user}

# download and install gerrit
RUN cd /tmp && wget ${g_url} && \
    mkdir ${g_gerrit_dir}/bin/ && \
    mv gerrit-${g_vrsn}.war  ${g_gerrit_dir}/bin/gerrit.war && \
    java -jar ${g_gerrit_dir}/bin/gerrit.war init --batch --install-all-plugins -d ${g_gerrit_dir}

# Allow incoming traffic
EXPOSE ${ssh_port} ${http_port}

# Download github auth plugin for gerrit and build it
# Checkout the 2.15.2 version -
# https://gerrit-review.googlesource.com/admin/repos/plugins/github,branches
RUN cd /tmp && git clone https://gerrit.googlesource.com/plugins/github && \
    cd github && \
    git checkout aaf5212deea02a0c266eab58e89fb735af95e1ea && \
    mvn install && \
    cp github-oauth/target/github-oauth-*.jar ${g_gerrit_dir}/lib/ && \
    cp github-plugin/target/github-plugin-*.jar ${g_gerrit_dir}/plugins/github.jar

# Install gravatar plugin
# Can't get this to work, manually copy in binary
#RUN cd /tmp && git clone https://gerrit.googlesource.com/plugins/avatars-gravatar && \
#    cd avatars-gravatar && \
#    mvn install && \
#    cp github-oauth/target/github-oauth-*.jar ${g_gerrit_dir}/lib/ && \

# install required crontab
RUN ( crontab -l ; echo "0 * * * * git -C ~/git/openbmc/openbmc.git push --follow-tags ssh://git@github.com/openbmc/openbmc master" ) | crontab
RUN ( crontab -l ; echo "0 * * * * git -C ~/git/openbmc/openbmc.git push --follow-tags ssh://git@github.ibm.com/openbmc/openbmc master" ) | crontab

USER root

CMD service postgresql start && \
    /etc/init.d/cron start && \
    sudo -i -u ${g_user} ${g_gerrit_dir}/bin/gerrit.sh start && \
    tail -f ${g_gerrit_dir}/logs/error_log
EOF
###############################################################################

# Build the image
docker build -t ${out_img} .
