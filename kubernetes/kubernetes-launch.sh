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
# Script Variables:
#  build_scripts_dir  The path for the openbmc-build-scripts directory.
#                     Default: The parent directory containing this script
#
# Kubernetes Variables:
#  imgplsec           The image pull secret used to access registry if needed
#                     Default: "regkey"
#  imgrepo            The registry to use to pull and push images
#                     Default: "master.cfc:8500/openbmc/""
#  jobtimeout         The amount of time in seconds that the build will wait for
#                     the job to be created in the api of the cluster.
#                     Default: "60"
#  namespace          The namespace to be used within the Kubernetes cluster
#                     Default: "openbmc"
#  podtimeout         The amount of time in seconds that the build will wait for
#                     the pod to start running on the cluster.
#                     Default: "600"
#
# YAML File Variables (No Defaults):
#  imgname            The name the image that will be passed to the kubernetes
#                     api to build the containers. The image with the tag
#                     imgname will be built in the invoker script. This script
#                     will then tag it to include the registry in the name, push
#                     it, and update the imgname to be what was pushed to the
#                     registry. Users should not include the registry in the
#                     original imgname.
#  podname            The name of the pod, needed to trace down the logs.
#
# Deployment Option Variables (No Defaults):
#  invoker            Name of what this script is being called by or for, used
#                     to determine the template to use for YAML file.
#  launch             Used to determine the template used for the YAML file,
#                     normally carried in by sourcing this script in another
#                     script that has declared it.
#  log                If set to true the script will tail the container logs
#                     as part of the bash script.
#  purge              If set to true it will delete the created object once this
#                     script ends.
#  workaround         Used to enable the logging workaround, when set will
#                     launch a modified template that waits for a command. In
#                     most cases it will be waiting to have a script run via
#                     kubectl exec. Required when using a version of Kubernetes
#                     that has known issues that impact the retrieval of
#                     container logs when using kubectl. Defaulting to be true
#                     whenever logging is enabled until ICP upgrades their
#                     Kubernetes version to a version that doesn't need this.
#
###############################################################################
build_scripts_dir=${build_scripts_dir:-"$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.."}

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
    wclaim=${wclaim:-jenkins-slave-space}
    sclaim=${sclaim:-shared-state-cache}
    oclaim=${oclaim:-openbmc-reference-repo}
    newimgname=${newimgname:-${imgrepo}${distro}:${imgtag}-${ARCH}}
    podname=${podname:-openbmc${BUILD_ID}-${target}-builder}
    ;;
  QEMU-build)
    podname=${podname:-qemubuild${BUILD_ID}}
    wclaim=${wclaim:-jenkins-slave-space}
    qclaim=${qclaim:-qemu-repo}
    newimgname="${imgrepo}${imgname}"
    ;;
  QEMU-launch)
    deployname=${deployname:-qemu-launch-deployment}
    podname=${podname:-qemu-instance}
    replicas=${replicas:-5}
    wclaim=${wclaim:-jenkins-slave-space}
    jenkins_subpath=${jenkins_subpath:-Openbmc-Build/openbmc/build}
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

extras=""
if [[ "${workaround}" == "true" ]]; then
  extras+="-v2"
fi

yamlfile=$(eval "echo \"$(<${build_scripts_dir}/kubernetes/Templates/${invoker}-${launch}${extras}.yaml)\"")
kubectl create -f - <<< "${yamlfile}"

# If launch is a job we have to find the podname with identifiers
if [[ "${launch}" == "job" ]]; then
  while [ -z ${replace} ]
  do
    if [ ${jobtimeout} -lt 0 ]; then
      kubectl delete -f - <<< "${yamlfile}"
      echo "Timeout occurred before job was present in the API"
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
      echo "Timeout occurred before pod was Running"
      exit 1
    else
      sleep 1
      let podtimeout-=1
    fi
    status=$( ${checkstatus} | grep Status: )
  done
  # Tail the logs of the pod, if workaround enabled start executing build script instead.
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
