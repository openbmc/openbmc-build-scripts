#!/bin/bash
################################################################################
# This script is used to deploy the kubernetes components that need to be
# present so that we can do an openbmc build job on a jenkins jnlp slave
# container. The way we do the docker registry access passing is a little bit of
# a security concern, recommended to use a dummy account that has access to the
# registry but not actually uses your w3id.
################################################################################
# Issue stems from the way the dockercfg is stored in the kubernetes api it will
# store the username, password and email in base64 encoded form. To workaround
# this issue I suggest using a group account that the group has access to to
# push/pull images to the internal registry.
#
# Use that account when filling out this script so that no ones P.I. is stored
# on the api.
################################################################################
# In regards to the NFS mounts, the NFS storage has to allow export to all
# the machines that work can land on. Otherwise an error will occur when k8s
# attempts to mount the NFS storage.
################################################################################

NS=${NS:-openbmc}
NFSIP=${NFSIP:-9.10.11.12}
NFSPrefix=${NFSPrefix:-/san}
imgrepo=${imgrepo:-k8s.icp:8500}
RECLAIM=Retain
username=${username:-user}
password=${password:-pass}
email=${email:-place@hol.der}

echo "Create the Jenkins Slave Workspace PVC"
NAME="jenkins-slave-space"
SIZE="100Gi"
MODE="ReadWriteMany"
NFSPATH="${NFSPrefix}/jenkins-slave-space"
source ./storage-setup.sh

echo "Create the Jenkins Configuration PVC"
NAME="jenkins-home"
SIZE="2Gi"
MODE="ReadWriteOnce"
NFSPATH="${NFSPrefix}/jenkins-master-home"
source ./storage-setup.sh

echo "Create the Shared State Cache PVC"
NAME="shared-state-cache"
SIZE="100Gi"
MODE="ReadWriteMany"
NFSPATH="${NFSPrefix}/sstate-cache"
source ./storage-setup.sh

echo "Create the Openbmc Reference PVC"
NAME="openbmc-reference-repo"
SIZE="1Gi"
MODE="ReadWriteMany"
NFSPATH="${NFSPrefix}/openbmc"
source ./storage-setup.sh

echo "Create the QEMU Reference PVC"
NAME="qemu-repo"
SIZE="1Gi"
MODE="ReadWriteMany"
NFSPATH="${NFSPrefix}/qemu"
source ./storage-setup.sh

# Create the regkey secret for the internal docker registry
kubectl create secret docker-registry regkey -n ${NS} \
--docker-username=${username} \
--docker-password=${password} \
--docker-email=${email} \
--docker-server=${registryserver}

# Create the docker config.json secret
base64up=$( echo -n ${username}:${password} | base64 )
cat >> config.json << EOF
{
	"auths": {
		"${registryserver}": {
			"auth": "${base64up}"
		}
	}

}
EOF
chmod ugo+rw config.json
kubectl create secret generic docker-config -n ${NS} --from-file=./config.json
