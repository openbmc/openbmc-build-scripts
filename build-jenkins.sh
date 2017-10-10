#!/bin/bash
################################################################################
# Script used to create a jenkins master that can run amd64 or ppc64le. It can
# be used to launch the jenkins master as a docker container locally or as a
# Kubernetes Deployment in a kubernetes cluster.
################################################################################
# Launch Variables:
#  These variables are used to determine how the master will be launched
#  launch             Method in which the container will be launched, either as
#                     a docker container launched via docker or by using a
#                     helper script to launch into Kubernetes. (docker or k8s)
#  HOME_MNT           The location used on the host for jenkins home directory
#  HOST_IMPORT_MNT    The directory on the host used to import extra files
#  CONT_IMPORT_MNT    The directory on the container used to import extra files
#
# Build Variables:
#  IMG_TAG            The tag for the OpenJDK image used to build the Dockerfile
#  WORKSPACE          The directory used to do the dockerfile build
#  TINI_VRSN          The version of tini to use in the dockerfile, 0.16.1 is
#                     the first release with ppc64le release support.
#  JENKINS_VRSN       The version of the jenkins war file you wish to use
#  juser              Jenkins user name tag for the container's jenkins user
#  jgroup             Jenkins group name tag for the container's jenkins user
#  juid               Jenkins user ID for the container's jenkins user
#  jgid               Jenkins group ID for the container's jenkins user
#  jhome              Directory that will be used as a home for jenkins user
#  http_port          The port used as Jenkins UI port
#  agent_port         The port used as the Jenkins slave agent port
#
################################################################################

set -xeo pipefail
ARCH=$(uname -m)

#Launch Variables
WORKSPACE=${WORKSPACE:-${HOME}/jenkins-build-${RANDOM}}
LAUNCH=${LAUNCH:-docker}
HOME_MNT=${HOME_MNT:-/mnt/jenkins}
HOST_IMPORT_MNT=${HOST_IMPORT_MNT:-/mnt/jimport}
CONT_IMPORT_MNT=${CONT_IMPORT_MNT:-/mnt/jimport}

#Dockerfile Variables
IMG_TAG=${IMG_TAG:-8-jdk}
JENKINS_VRSN=${JENKINS_VRSN:-2.60.3}
TINI_VRSN=${TINI_VRSN:-0.16.1}
juser=${juser:-jenkins}
jgroup=${jgroup:-jenkins}
juid=${juid:-1000}
jgid=${jgid:-1000}
jhome=${jhome:-/var/jenkins_home}
http_port=${http_port:-8080}
agent_port=${agent_port:-50000}
OUT_IMG=${OUT_IMG:-openbmc/jenkins-master-${ARCH}:${JENKINS_VRSN}}

#Save the Jenkins.war URL to a variable and SHA if we care about verification
JENKINS_URL=https://repo.jenkins-ci.org/public/org/jenkins-ci/main/jenkins-war/${JENKINS_VRSN}/jenkins-war-${JENKINS_VRSN}.war
#JENKINS_SHA=2d71b8f87c8417f9303a73d52901a59678ee6c0eefcf7325efed6035ff39372a

# Make or Clean WORKSPACE
if [[ -d ${WORKSPACE} ]]; then
  rm -rf ${WORKSPACE}/Dockerfile \
         ${WORKSPACE}/docker-jenkins \
         ${WORKSPACE}/plugins.* \
         ${WORKSPACE}/install-plugins.sh \
         ${WORKSPACE}/jenkins* \
         ${WORKSPACE}/init.groovy
else
  mkdir -p ${WORKSPACE}
fi

# Determine the prefix of the Dockerfile's base image
case ${ARCH} in
  "ppc64le")
    DOCKER_BASE="ppc64le/"
    TINI_ARCH="ppc64el"
    ;;
  "x86_64")
    DOCKER_BASE=""
    TINI_ARCH="amd64"
    ;;
  *)
    echo "Unsupported system architecture(${ARCH}) found for docker image"
    exit 1
esac

# Move Into the WORKSPACE
cd ${WORKSPACE}

#Make the Dockerfile
cat >> Dockerfile << EOF
FROM ${DOCKER_BASE}openjdk:${IMG_TAG}

RUN apt-get update && apt-get install -y git curl

ENV JENKINS_HOME ${jhome}
ENV JENKINS_SLAVE_AGENT_PORT ${agent_port}

# Jenkins is run with user `jenkins`, uid = 1000
# If you bind mount a volume from the host or a data container,
# ensure you use the same uid
RUN groupadd -g ${jgid} ${jgroup} \
    && useradd -d ${jhome} -u ${juid} -g ${jgid} -m -s /bin/bash ${juser}

# Jenkins home directory is a volume, so configuration and build history
# can be persisted and survive image upgrades
VOLUME ${jhome}

# `/usr/share/jenkins/ref/` contains all reference configuration we want
# to set on a fresh new installation. Use it to bundle additional plugins
# or config file with your custom jenkins Docker image.
RUN mkdir -p /usr/share/jenkins/ref/init.groovy.d

# Use tini as subreaper in Docker container to adopt zombie processes
RUN curl -fsSL https://github.com/krallin/tini/releases/download/v${TINI_VRSN}/tini-static-${TINI_ARCH} \
    -o /bin/tini \
    && chmod +x /bin/tini

COPY init.groovy /usr/share/jenkins/ref/init.groovy.d/tcp-slave-agent-port.groovy

# could use ADD but this one does not check Last-Modified header neither does it allow to control checksum
# see https://github.com/docker/docker/issues/8331
RUN curl -fsSL ${JENKINS_URL} -o /usr/share/jenkins/jenkins.war #\
#  && echo "${JENKINS_SHA}  /usr/share/jenkins/jenkins.war" | sha256sum -c -

ENV JENKINS_UC https://updates.jenkins.io
ENV JENKINS_UC_EXPERIMENTAL=https://updates.jenkins.io/experimental
RUN chown -R ${juser} ${jhome} /usr/share/jenkins/ref

# for main web interface:
EXPOSE ${http_port}

# will be used by attached slave agents:
EXPOSE ${agent_port}

ENV COPY_REFERENCE_FILE_LOG ${jhome}/copy_reference_file.log
USER ${juser}

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

#Clone in the jenkinsci docker jenkins repo and copy some files into WORKSPACE
git clone https://github.com/jenkinsci/docker.git docker-jenkins
cp docker-jenkins/init.groovy .
cp docker-jenkins/jenkins-support .
cp docker-jenkins/jenkins.sh .
cp docker-jenkins/plugins.sh .
cp docker-jenkins/install-plugins.sh .

# Generate Plugins.txt, plugins you want installed automatically go here
cat >> plugins.txt << EOF
kubernetes
EOF

# Build the image
docker build --pull -t ${OUT_IMG} .

if [[ ${LAUNCH} == "docker" ]]; then

  # Ensure directories that will be mounted exist
  if [[ ! -d ${HOST_IMPORT_MNT} ]]; then
    mkdir -p ${HOST_IMPORT_MNT}
  fi
  if [[ ! -d ${HOME_MNT} ]]; then
    mkdir -p ${HOME_MNT}
  fi

  # Ensure directories tht will be mounted are owned by the jenkins user
  if [[ "$(id -u)" != 0 ]]; then
    echo "Not running as root:"
    echo "Checking if jgid and juid are the owners of mounted directories"
    test1=$(ls -nd ${HOME_MNT} | awk '{print $3 " " $4}')
    test2=$(ls -nd ${HOST_IMPORT_MNT} | awk '{print $3 " " $4}' )
    if [[ "${test1}" != "${juid} ${jgid}" ]]; then
      echo "Owner of ${HOME_MNT} is not the jenkins user"
      echo "${test1} != ${juid} ${jgid}"
      settofail=true
    fi
    if [[ "${test2}" != "${juid} ${jgid}" ]]; then
      echo "Owner of ${HOST_IMPORT_MNT} is not the jenkins user"
      echo "${test2} != ${juid} ${jgid}"
      settofail=true
    fi
    if [[ "${settofail}" == "true" ]]; then
      echo "Failing before attempting to launch container"
      echo "Try again as root or use correct uid/gid pairs"
      exit 1
    fi
  else
    chown -R ${juid}:${jgid} ${HOST_IMPORT_MNT}
    chown -R ${juid}:${jgid} ${HOME_MNT}
  fi

  # Launch the jenkins image with Docker
  docker run -d \
    -v ${HOST_IMPORT_MNT}:${CONT_IMPORT_MNT} \
    -v ${HOME_MNT}:${jhome} \
    -p ${http_port}:8080 \
    -p ${agent_port}:${agent_port} \
    ${OUT_IMG}

elif [[ ${LAUNCH} == "k8s" ]]; then
  # launch using the k8s template
  echo "Not yet Implemented"
  exit 1
  source ./kubernetes/kubernetes-launch.sh Build-Jenkins false false

fi