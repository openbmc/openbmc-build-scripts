#!/bin/bash
################################################################################
# Script used to create a Jenkins master that can run amd64 or ppc64le. It can
# be used to launch the Jenkins master as a Docker container locally or as a
# Kubernetes Deployment in a Kubernetes cluster.
################################################################################
# Launch Variables:
#  These variables are used to determine how the master will be launched
#  workspace          The directory that hold files used to deploy the Jenkins
#                     master
#                     Default: "${HOME}/jenkins-build-${RANDOM}"
#  launch             Method in which the container will be launched, either as
#                     a Docker container launched via Docker or by using a
#                     helper script to launch into Kubernetes (docker or k8s)
#                     Default: "docker"
#  home_mnt           The directory on the host used as the Jenkins home
#                     Default: "${WORKSPACE}/jenkins_home"
#  host_import_mnt    The directory on the host used to import extra files
#                     Default: "${WORKSPACE}/jenkins_import"
#  cont_import_mnt    The directory on the container used to import extra files
#                     Default: "/mnt/jenkins_import"
#
# Build Variables:
#  img_tag            The tag for the OpenJDK image used to build the Dockerfile
#                     Default: "/8-jdk"
#  tini_vrsn          The version of Tini to use in the dockerfile, 0.16.1 is
#                     the first release with ppc64le release support
#                     Default: "0.16.1"
#  j_vrsn             The version of the Jenkins war file you wish to use
#                     Default: "2.60.3"
#  j_user             Username tag the container will use to run Jenkins
#                     Default: "jenkins"
#  j_group            Group name tag the container will use to run Jenkins
#                     Default: "jenkins"
#  j_uid              Jenkins user ID the container will use to run Jenkins
#                     Default: "1000"
#  j_gif              Jenkins group ID the container will use to run Jenkins
#                     Default: "1000"
#  j_home             Directory used as the Jenkins Home in the container
#                     Default: "${WORKSPACE}/jenkins_home"
#  http_port          The port used as Jenkins UI port
#                     Default: "8080"
#  agent_port         The port used as the Jenkins slave agent port
#                     Default: "50000"
#  out_img            The name given to the Docker image when it is built
#                     Default: "openbmc/jenkins-master-${ARCH}:${JENKINS_VRSN}"
#
################################################################################

set -xeo pipefail
ARCH=$(uname -m)

#Launch Variables
workspace=${workspace:-${HOME}/jenkins-build-${RANDOM}}
launch=${launch:-docker}
home_mnt=${home_mnt:-${workspace}/jenkins_home}
host_import_mnt=${host_import_mnt:-${workspace}/jenkins_import}
cont_import_mnt=${cont_import_mnt:-/mnt/jenkins_import}

#Dockerfile Variables
img_tag=${img_tag:-8-jdk}
tini_vrsn=${tini_vrsn:-0.16.1}
j_vrsn=${j_vrsn:-2.60.3}
j_user=${j_user:-jenkins}
j_group=${j_group:-jenkins}
j_uid=${j_uid:-1000}
j_gid=${j_gid:-1000}
j_home=${j_home:-/var/jenkins_home}
agent_port=${http_port:-8080}
agent_port=${agent_port:-50000}
out_img=${out_img:-openbmc/jenkins-master-${ARCH}:${JENKINS_VRSN}}

#Save the Jenkins.war URL to a variable and SHA if we care about verification
j_url=https://repo.jenkins-ci.org/public/org/jenkins-ci/main/jenkins-war/${j_vrsn}/jenkins-war-${j_vrsn}.war
#j_sha=2d71b8f87c8417f9303a73d52901a59678ee6c0eefcf7325efed6035ff39372a

# Make or Clean WORKSPACE
if [[ -d ${workspace} ]]; then
  rm -rf ${workspace}/Dockerfile \
         ${workspace}/docker-jenkins \
         ${workspace}/plugins.* \
         ${workspace}/install-plugins.sh \
         ${workspace}/jenkins.sh \
         ${workspace}/jenkins-support \
         ${workspace}/init.groovy
else
  mkdir -p ${workspace}
fi

# Determine the prefix of the Dockerfile's base image
case ${ARCH} in
  "ppc64le")
    docker_base="ppc64le/"
    tini_arch="ppc64el"
    ;;
  "x86_64")
    docker_base=""
    tini_arch="amd64"
    ;;
  *)
    echo "Unsupported system architecture(${ARCH}) found for docker image"
    exit 1
esac

# Move Into the WORKSPACE
cd ${workspace}

#Make the Dockerfile
################################################################################
cat >> Dockerfile << EOF
FROM ${docker_base}openjdk:${img_tag}

RUN apt-get update && apt-get install -y git curl

ENV JENKINS_HOME ${j_home}
ENV JENKINS_SLAVE_AGENT_PORT ${agent_port}

# Jenkins is run with user `jenkins`, uid = 1000
# If you bind mount a volume from the host or a data container,
# ensure you use the same uid
RUN groupadd -g ${j_gid} ${j_group} \
    && useradd -d ${j_home} -u ${j_uid} -g ${j_gid} -m -s /bin/bash ${j_user}

# Jenkins home directory is a volume, so configuration and build history
# can be persisted and survive image upgrades
VOLUME ${j_home}

# `/usr/share/jenkins/ref/` contains all reference configuration we want
# to set on a fresh new installation. Use it to bundle additional plugins
# or config file with your custom jenkins Docker image.
RUN mkdir -p /usr/share/jenkins/ref/init.groovy.d

# Use tini as subreaper in Docker container to adopt zombie processes
RUN curl -fsSL https://github.com/krallin/tini/releases/download/v${tini_vrsn}/tini-static-${tini_arch} \
    -o /bin/tini \
    && chmod +x /bin/tini

COPY init.groovy /usr/share/jenkins/ref/init.groovy.d/tcp-slave-agent-port.groovy

# could use ADD but this one does not check Last-Modified header neither does it allow to control checksum
# see https://github.com/docker/docker/issues/8331
RUN curl -fsSL ${j_url} -o /usr/share/jenkins/jenkins.war #\
#  && echo "${JENKINS_SHA}  /usr/share/jenkins/jenkins.war" | sha256sum -c -

ENV JENKINS_UC https://updates.jenkins.io
ENV JENKINS_UC_EXPERIMENTAL=https://updates.jenkins.io/experimental
RUN chown -R ${j_user} ${j_home} /usr/share/jenkins/ref

# for main web interface:
EXPOSE ${http_port}

# will be used by attached slave agents:
EXPOSE ${agent_port}

ENV COPY_REFERENCE_FILE_LOG ${j_home}/copy_reference_file.log
USER ${j_user}

COPY jenkins-support /usr/local/bin/jenkins-support
COPY jenkins.sh /usr/local/bin/jenkins.sh
ENTRYPOINT ["/bin/tini", "--", "/usr/local/bin/jenkins.sh"]

# from a derived Dockerfile, can use `RUN plugins.sh active.txt` to setup /usr/share/jenkins/ref/plugins from a support bundle
COPY plugins.sh /usr/local/bin/plugins.sh
COPY install-plugins.sh /usr/local/bin/install-plugins.sh

# Install plugins.txt plugins
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN /usr/local/bin/install-plugins.sh < /usr/share/jenkins/ref/plugins.txt
EOF
################################################################################

#Clone in the jenkinsci docker jenkins repo and copy some files into WORKSPACE
git clone https://github.com/jenkinsci/docker.git docker-jenkins
cp docker-jenkins/init.groovy .
cp docker-jenkins/jenkins-support .
cp docker-jenkins/jenkins.sh .
cp docker-jenkins/plugins.sh .
cp docker-jenkins/install-plugins.sh .

# Generate Plugins.txt, the plugins you want installed automatically go here
################################################################################
cat >> plugins.txt << EOF
kubernetes
EOF
################################################################################

# Build the image
docker build --pull -t ${out_img} .

if [[ ${launch} == "docker" ]]; then

  # Ensure directories that will be mounted exist
  if [[ ! -d ${host_import_mnt} ]]; then
    mkdir -p ${host_import_mnt}
  fi
  if [[ ! -d ${home_mnt} ]]; then
    mkdir -p ${home_mnt}
  fi

  # Ensure directories tht will be mounted are owned by the jenkins user
  if [[ "$(id -u)" != 0 ]]; then
    echo "Not running as root:"
    echo "Checking if jgid and juid are the owners of mounted directories"
    test1=$(ls -nd ${home_mnt} | awk '{print $3 " " $4}')
    test2=$(ls -nd ${host_import_mnt} | awk '{print $3 " " $4}' )
    if [[ "${test1}" != "${j_uid} ${j_gid}" ]]; then
      echo "Owner of ${home_mnt} is not the jenkins user"
      echo "${test1} != ${j_uid} ${j_gid}"
      willfail=1
    fi
    if [[ "${test2}" != "${j_uid} ${j_gid}" ]]; then
      echo "Owner of ${host_import_mnt} is not the jenkins user"
      echo "${test2} != ${j_uid} ${j_gid}"
      willfail=1
    fi
    if [[ "${willfail}" == 1 ]]; then
      echo "Failing before attempting to launch container"
      echo "Try again as root or use correct uid/gid pairs"
      exit 1
    fi
  else
    chown -R ${j_uid}:${j_gid} ${host_import_mnt}
    chown -R ${j_uid}:${j_gid} ${home_mnt}
  fi

  # Launch the jenkins image with Docker
  docker run -d \
    -v ${host_import_mnt}:${cont_import_mnt} \
    -v ${home_mnt}:${j_home} \
    -p ${http_port}:8080 \
    -p ${agent_port}:${agent_port} \
    ${out_img}

elif [[ ${launch} == "k8s" ]]; then
  # launch using the k8s template
  echo "Not yet Implemented"
  exit 1
  source ./kubernetes/kubernetes-launch.sh Build-Jenkins false false
fi