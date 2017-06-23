#!/bin/bash
###############################################################################
#
# Script used to assist in launching Kubernetes jobs/pods. Expects to be used
# as an supplemental script to the scripts that want to launch their containers
# on a Kubernetes cluster.
#
###############################################################################
#
# Requirements:
#  - Docker login credentials defined inside ~/.docker/config.json
#  - Kubectl installed and configured on machine running the script
#  - Access to a Kubernetes Cluster using v1.5.2 or newer
#  - NFS directories for OpenBMC repo cache, BitBake shared state cache, and
#    shared Jenkins home directory that holds workspaces.
#  - All NFS directories should have RWX permissions for user being used to run
#    the build-setup.sh script
#  - Persistent Volume and Claims created and mounted to NFS directories
#  - Image pull secret exists for image pulls in Kubernetes cluster namespace
#
###############################################################################
# Variables used to create Kubernetes Job:
#  namespace    = the namespace to be used within the Kubernetes cluster
#  registry     = the registry to use to pull and push images
#  imgplsec     = the image pull secret used to access registry if needed
#  timeout      = the amount of time in seconds that the build will wait for
#                 the pod to start running on the cluster
#  imgname      = the name the image will be given when built, must include
#                 the repo in name for the push command to work.
#  podname      = the name of the pod, will be needed to trace down the logs
#
###############################################################################
# Variables that act as script options:
#  invoker      = name of what this script is being called by or for, used to
#                 determine the template to use for YAML file
#  log          = set to true to make the script tail the container logs of pod
#  purge        = set to true delete the created object once script completes
#  launch       = used to determine the template for YAML file, Usually brought
#                 in by sourcing from another script but can be declared
#
###############################################################################

# Kubernetes Variables
namespace=${namespace:-openbmc}
imgrepo=${imgrepo:-master.cfc:8500/openbmc/}
imgplsec=${imgplsec:-regkey}
timeout=${timeout:-60}

# Options which decide script behavior
invoker=${invoker:-${1}}
log=${log:-${2}}
purge=${purge:-${3}}
launch=${launch:-${4}}

# Set the variables for the specific invoker to fill in the YAML template
# Other variables in the template not declared here are expected to be declared by invoker.
case ${invoker} in
  OpenBMC-build)
    hclaim=${hclaim:-jenkins}
    sclaim=${sclaim:-shared-state-cache}
    oclaim=${oclaim:-openbmc-reference-repo}
    imgname=${imgname:-${imgrepo}${distro}:${imgtag}-${ARCH}}
    podname=${podname:-openbmc${BUILD_ID}-${target}-builder}
    ;;
  QEMU-build)
    podname=${podname:-qemubuild${BUILD_ID}}
    hclaim=${hclaim:-jenkins}
    qclaim=${qclaim:-qemu-repo}
    imgname="${imgrepo}${imgname}"
    ;;
  QEMU-launch)
    ;;
  XCAT-launch)
    ;;
  generic)
    ;;
  *)
    exit 1
    ;;
esac


# Build the Docker image, using the Dockerfile carried from build-setup.sh
docker build -t ${imgname} - <<< "${Dockerfile}"

# Push the image that was built to the image repository
docker push ${imgname}

yamlfile=$(eval "echo \"$(<./kubernetes/Templates/${invoker}-${launch}.yaml)\"" )
kubectl create -f - <<< "${yamlfile}"

# Once pod is running track logs
if [[ "${log}" == true ]]; then
  # Wait for Pod to be running
  while [ -z "$(kubectl describe pod ${podname} -n ${namespace} | grep Status: | grep Running)" ]; do
    if [ ${timeout} -lt 0 ];then
      kubectl delete -f - <<< "${yamlfile}"
      echo "Timeout Occured: Job failed to start running in time"
      exit 1
    else
      sleep 1
      let timeout-=1
    fi
  done
  kubectl logs -f ${podname} -n ${namespace}
fi

# Delete the object if purge is true
if [[ "${purge}" == true ]]; then
  kubectl delete -f - <<< "${yamlfile}"
fi
