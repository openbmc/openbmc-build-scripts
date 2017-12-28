#!/bin/bash
###############################################################################
#
# This script is for initializing the Kubernetes environement needed to run all
# the kubernetes integrated scripts in Kubernetes.
# - Provisions the PV's and PVC's for:
#   * The Kubernetes JNLP Jenkins slave's shared workspace
#   * Shared state cache
#   * Openbmc/openbmc git reference repository
#   * Openbmc/qemu git reference repository
# - Create docker-registry secret for pulling from the internal repo
# - Create the config.json used to mount docker configuration to Kubernetes
#   Jenkins slaves that build and push docker images via shell scripts.
# Optionally:
# - Launch a Jenkins Master deployment into Kubernetes.
# - Provision the PV and PVC for the Jenkin Master home directory
#
# Instructions:
#  Suggested way to run is to create a seperate script that will export all the
#  necessary variables and then source in this script. But editing this one
#  works as well.
#
###############################################################################
#
# Requirements:
#  - NFS server with directory to use as path for mount
#  - Access to an existing Kubernetes Cluster
#  - Kubectl installed and configured on machine running script
#
###############################################################################
#
# Variables used to initialize environment:
#  ns           = Name of namespace we will be deploying the components into,
#                 defaults to "openbmc".
#  nfsip        = IP address of the NFS server we will be using for mounting a
#                 Persistent Volume (PV) to, defaults to "10.0.0.0", should be
#                 replaced with an actual IP address of an NFS server.
#  reclaim      = The reclaim policy that will be used when creating the PV
#                 look at k8s docs for more info on this. Defaults to "Retain".
#  path_prefix  = The prefix we will add to the nfspath of the directories we
#                 intend to mount. This is used to place all the different
#                 directories into the same parent folder on the NFS server.
#                 defaults to "/san_mount/openbmc_k8s", should be changed to
#                 a valid path on your NFS server.
#  regserver    = The docker registry which will be used when pushing and
#                 pulling images. For internal use, it will be the internal
#                 registry created by ICP, defaults to "master.icp:8500" must
#                 be changed to an actual registry.
#  username     = The username that will be used to login to the regserver,
#                 defaults to "admin", should be changed.
#  pass         = The password that will be used to login to the regserver,
#                 defaults to "password", should be changed.
#  email        = The email that will be used to login to the regserver,
#                 defaults to "email@place.holder", should be changed.
#  k8s_master   = Set to True if you want to deploy a Jenkins Master into k8s,
#                 defaults to True.
###############################################################################

build_scripts_dir=${build_scripts_dir:-"$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.."}

ns=${ns:-openbmc}
nfsip=${nfsip:-10.0.0.0}
regserver=${regserver:-master.icp:8500}
reclaim=${reclaim:-Retain}
path_prefix=${path_prefix:-/san_mount/openbmc_k8s}
username=${username:-admin}
pass=${pass:-password}
email=${email:-email\@place.holder}
k8s_master=${k8s_master:-True}

echo "Create the Jenkins Slave Workspace PVC"
name="jenkins-slave-space"
size="100Gi"
mode="ReadWriteMany"
nfspath="${path_prefix}/jenkins-slave-space"
source ${build_scripts_dir}/kubernetes/storage-setup.sh

echo "Create the Shared State Cache PVC"
name="shared-state-cache"
size="100Gi"
mode="ReadWriteMany"
nfspath="${path_prefix}/sstate-cache"
source ${build_scripts_dir}/kubernetes/storage-setup.sh

echo "Create the Openbmc Reference PVC"
name="openbmc-reference-repo"
size="1Gi"
mode="ReadWriteMany"
nfspath="${path_prefix}/openbmc"
source ${build_scripts_dir}/kubernetes/storage-setup.sh

echo "Create the QEMU Reference PVC"
name="qemu-repo"
size="1Gi"
mode="ReadWriteMany"
nfspath="${path_prefix}/qemu"
source ${build_scripts_dir}/kubernetes/storage-setup.sh

# Create the regkey secret for the internal docker registry
kubectl create secret docker-registry regkey -n $ns \
--docker-username=${username} \
--docker-password=${pass} \
--docker-email=${email} \
--docker-server=${regserver}

# Create the docker config.json secret using the base64 encode of
# '${username}:${pass}'

base64up=$( echo -n "${username}:${pass}" | base64 )
cat >> config.json << EOF
{
  "auths": {
    "${regserver}": {
      "auth": "${base64up}"
    }
  }
}
EOF

chmod ugo+rw config.json
kubectl create secret generic docker-config -n $ns --from-file=./config.json
rm -f ./config.json

if [[ "${k8s_master}" ==  "True" ]]; then
  # Create the Jenkins Master Home PVC
  echo "Create the Jenkins Master Home PVC"
  name="jenkins-home"
  size="2Gi"
  mode="ReadWriteOnce"
  nfspath="${path_prefix}/jenkins-master-home"
  source ${build_scripts_dir}/kubernetes/storage-setup.sh

  # Launch the Jenkins Master
  launch="k8s"
  # Clean up variables before sourcing the build-jenkins.sh
  unset ns \
  nfsip \
  regserver \
  reclaim \
  path_prefix \
  username \
  pass email
  source ${build_scripts_dir}/build-jenkins.sh
fi
