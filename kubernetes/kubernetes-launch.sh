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
#  jobtimeout   = the amount of time in seconds that the build will wait for
#                 the job to be created in the api of the cluster.
#  podtimeout   = the amount of time in seconds that the build will wait for
#                 the pod to start running on the cluster.
#  imgname      = the name the image that will be passed to the kubernetes api
#                 to build the containers. The image with the tag imgname will
#                 be built in the invoker script. This script will then tag it
#                 to include the registry in the name, push it, and update the
#                 imgname to be what was pushed to the registry. Users should
#                 not include the registry in the original imgname.
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
#  workaround   = set to true if we are using the workaround to kubernetes
#                 version issues
###############################################################################

# Kubernetes Variables
namespace=${namespace:-openbmc}
imgrepo=${imgrepo:-master.cfc:8500/openbmc/}
imgplsec=${imgplsec:-regkey}
jobtimeout=${jobtimeout:-60}
podtimeout=${podtimeout:-600}

# Options which decide script behavior
invoker=${invoker:-${1}}
log=${log:-${2}}
purge=${purge:-${3}}
launch=${launch:-${4}}
workaround=${workaround:-${log}}

# Set the variables for the specific invoker to fill in the YAML template
# Other variables in the template not declared here are declared by invoker
case ${invoker} in
  OpenBMC-build)
    hclaim=${hclaim:-jenkins-slave-space}
    sclaim=${sclaim:-shared-state-cache}
    oclaim=${oclaim:-openbmc-reference-repo}
    newimgname=${newimgname:-${imgrepo}${distro}:${imgtag}-${ARCH}}
    podname=${podname:-openbmc${BUILD_ID}-${target}-builder}
    ;;
  QEMU-build)
    podname=${podname:-qemubuild${BUILD_ID}}
    hclaim=${hclaim:-jenkins-slave-space}
    qclaim=${qclaim:-qemu-repo}
    newimgname="${imgrepo}${imgname}"
    ;;
  QEMU-launch)
    deployname=${deployname:-qemu-launch-deployment}
    podname=${podname:-qemu-instance}
    replicas=${replicas:-5}
    hclaim=${hclaim:-jenkins-slave-space}
    jenkins_subpath=${jenkins_subpath:-workspace/Openbmc-Build/openbmc/build}
    newimgname="${imgrepo}qemu-instance"
    ;;
  XCAT-launch)
    ;;
  generic)
    ;;
  *)
    exit 1
    ;;
esac

# Tag the image created by the invoker with a name that includes the imgrepo
docker tag ${imgname} ${newimgname}
imgname=${newimgname}

# Push the image that was built to the image repository
docker push ${imgname}

if [[ "$ARCH" == x86_64 ]]; then
  ARCH=amd64
fi

if [[ "${workaround}" == "true" ]]; then
  extras="-v2"
else
  extras=""
fi

yamlfile=$(eval "echo \"$(<./kubernetes/Templates/${invoker}-${launch}${extras}.yaml)\"")
kubectl create -f - <<< "${yamlfile}"

# If launch is a job we have to find the podname with identifiers
if [[ "${launch}" == "job" ]]; then
  while [ -z ${replace} ]
  do
    if [ ${jobtimeout} -lt 0 ]; then
      kubectl delete -f - <<< "${yamlfile}"
      echo "Timeout occured before job was present in the API"
      exit 1
    else
      sleep 1
      let jobtimeout-=1
    fi
    replace=$(kubectl get pods -n ${namespaces} | grep ${podname} | awk 'print $1')
  done
  podname=${replace}
fi


# Once pod is running track logs
if [[ "${log}" == true ]]; then
  # Wait for Pod to be running
  checkstatus="kubectl describe pod ${podname} -n ${namespace}"
  status=$( ${checkstatus} | grep Status: )
  while [ -z "$( echo ${status} | grep Running)" ]
  do
    if [ ${podtimeout} -lt 0 ]; then
      kubectl delete -f - <<< "${yamlfile}"
      echo "Timeout occured before pod was Running"
      exit 1
    else
      sleep 1
      let podtimeout-=1
    fi
    status=$( ${checkstatus} | grep Status: )
  done
  # Tail the logs of the pod
  if [[ "${workaround}" == "true" ]]; then
    kubectl exec -it ${podname} -n ${namespace} ${WORKSPACE}/build.sh
  else
    kubectl logs -f ${podname} -n ${namespace}
  fi
fi

# Delete the object if purge is true
if [[ "${purge}" == true ]]; then
  kubectl delete -f - <<< "${yamlfile}"
fi
