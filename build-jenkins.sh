#!/bin/bash
################################################################################
# Script used to create a Jenkins master that can run amd64 or ppc64le. It can
# be used to launch the Jenkins master as a Docker container locally or as a
# Kubernetes Deployment in a Kubernetes cluster.
################################################################################
# Launch Variables:
#  These variables are used to determine how the master will be launched
#  WORKSPACE          The directory that hold files used to deploy the Jenkins
#                     master
#                     Default: "${HOME}/jenkins-build-${RANDOM}"
#  LAUNCH             Method in which the container will be launched, either as
#                     a Docker container launched via Docker or by using a
#                     helper script to launch into Kubernetes (docker or k8s)
#                     Default: "docker"
#  HOME_MNT           The directory on the host used as the Jenkins home
#                     Default: "${WORKSPACE}/jenkins_home"
#  HOST_IMPORT_MNT    The directory on the host used to import extra files
#                     Default: "${WORKSPACE}/jenkins_import"
#  CONT_IMPORT_MNT    The directory on the container used to import extra files
#                     Default: "/mnt/jenkins_import"
#
# Build Variables:
#  IMG_TAG            The tag for the OpenJDK image used to build the Dockerfile
#                     Default: "/8-jdk"
#  TINI_VRSN          The version of Tini to use in the dockerfile, 0.16.1 is
#                     the first release with ppc64le release support
#                     Default: "0.16.1"
#  JENKINS_VRSN       The version of the Jenkins war file you wish to use
#                     Default: "2.60.3"
#  J_USER             Username tag the container will use to run Jenkins
#                     Default: "jenkins"
#  J_GROUP            Group name tag the container will use to run Jenkins
#                     Default: "jenkins"
#  J_UID              Jenkins user ID the container will use to run Jenkins
#                     Default: "1000"
#  J_GID              Jenkins group ID the container will use to run Jenkins
#                     Default: "1000"
#  J_HOME             Directory used as the Jenkins Home in the container
#                     Default: "${WORKSPACE}/jenkins_home"
#  HTTP_PORT          The port used as Jenkins UI port
#                     Default: "8080"
#  AGENT_PORT         The port used as the Jenkins slave agent port
#                     Default: "50000"
#  OUT_IMG            The name given to the Docker image when it is built
#                     Default: "openbmc/jenkins-master-${ARCH}:${JENKINS_VRSN}"
#
################################################################################

set -xeo pipefail
ARCH=$(uname -m)

#Launch Variables
WORKSPACE=${WORKSPACE:-${HOME}/jenkins-build-${RANDOM}}
LAUNCH=${LAUNCH:-docker}
HOME_MNT=${HOME_MNT:-${WORKSPACE}/jenkins_home}
HOST_IMPORT_MNT=${HOST_IMPORT_MNT:-${WORKSPACE}/jenkins_import}
CONT_IMPORT_MNT=${CONT_IMPORT_MNT:-/mnt/jenkins_import}

#Dockerfile Variables
IMG_TAG=${IMG_TAG:-8-jdk}
JENKINS_VRSN=${JENKINS_VRSN:-2.60.3}
TINI_VRSN=${TINI_VRSN:-0.16.1}
J_USER=${J_USER:-jenkins}
J_GROUP=${J_GROUP:-jenkins}
J_UID=${J_UID:-1000}
J_GID=${J_GID:-1000}
J_HOME=${J_HOME:-/var/jenkins_home}
HTTP_PORT=${HTTP_PORT:-8080}
AGENT_PORT=${AGENT_PORT:-50000}
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
         ${WORKSPACE}/jenkins.sh \
         ${WORKSPACE}/jenkins-support \
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

ENV JENKINS_HOME ${J_HOME}
ENV JENKINS_SLAVE_AGENT_PORT ${AGENT_PORT}

# Jenkins is run with user `jenkins`, uid = 1000
# If you bind mount a volume from the host or a data container,
# ensure you use the same uid
RUN groupadd -g ${J_GID} ${J_GROUP} \
    && useradd -d ${J_HOME} -u ${J_UID} -g ${J_GID} -m -s /bin/bash ${J_USER}

# Jenkins home directory is a volume, so configuration and build history
# can be persisted and survive image upgrades
VOLUME ${J_HOME}

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
RUN chown -R ${J_USER} ${J_HOME} /usr/share/jenkins/ref

# for main web interface:
EXPOSE ${HTTP_PORT}

# will be used by attached slave agents:
EXPOSE ${AGENT_PORT}

ENV COPY_REFERENCE_FILE_LOG ${J_HOME}/copy_reference_file.log
USER ${J_USER}

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
    TEST1=$(ls -nd ${HOME_MNT} | awk '{print $3 " " $4}')
    TEST2=$(ls -nd ${HOST_IMPORT_MNT} | awk '{print $3 " " $4}' )
    if [[ "${TEST1}" != "${J_UID} ${J_GID}" ]]; then
      echo "Owner of ${HOME_MNT} is not the jenkins user"
      echo "${TEST1} != ${J_UID} ${J_GID}"
      WILLFAIL=true
    fi
    if [[ "${TEST2}" != "${J_UID} ${J_GID}" ]]; then
      echo "Owner of ${HOST_IMPORT_MNT} is not the jenkins user"
      echo "${TEST2} != ${J_UID} ${J_GID}"
      WILLFAIL=true
    fi
    if [[ "${WILLFAIL}" == "true" ]]; then
      echo "Failing before attempting to launch container"
      echo "Try again as root or use correct uid/gid pairs"
      exit 1
    fi
  else
    chown -R ${J_UID}:${J_GID} ${HOST_IMPORT_MNT}
    chown -R ${J_UID}:${J_GID} ${HOME_MNT}
  fi

  # Launch the jenkins image with Docker
  docker run -d \
    -v ${HOST_IMPORT_MNT}:${CONT_IMPORT_MNT} \
    -v ${HOME_MNT}:${J_HOME} \
    -p ${HTTP_PORT}:8080 \
    -p ${AGENT_PORT}:${AGENT_PORT} \
    ${OUT_IMG}

elif [[ ${LAUNCH} == "k8s" ]]; then
  # launch using the k8s template
  echo "Not yet Implemented"
  exit 1
  source ./kubernetes/kubernetes-launch.sh Build-Jenkins false false

fi