#!/bin/bash
###############################################################################
#
# Script used to assist in launching Kubernetes jobs/pods. Expects to be used
# as an supplemental script to the build-setup.sh script as such will use some
# of the variables it expects to carry over from that script.
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
#  hclaim       = name of the Jenkins slave home PVC on Kubernetes cluster
#  sclaim       = name of the shared state cache PVC on Kubernetes cluster
#  oclaim       = name of OpenBMC cache repo PVC on the Kubernetes cluster
#  registry     = the registry to use to pull and push images
#  imgplsec     = the image pull secret used to access registry if needed
#  timeout      = the amount of time in seconds that the build will wait for
#                 the pod to start running on the cluster
#  imgname      = the name the image will be given when built, must include
#                 the repo in name for the push command to work.
#  podname      = the name of the pod, will be needed to trace down the logs
#
###############################################################################

# Kubernetes Variables
namespace=${namespace:-openbmc}
hclaim=${hclaim:-jenkins}
sclaim=${sclaim:-shared-state-cache}
oclaim=${oclaim:-openbmc-reference-repo}
imgrepo=${imgrepo:-master.cfc:8500/openbmc/}
imgplsec=${imgplsec:-regkey}
timeout=${timeout:-60}

# Give the Docker image and the pod a name
imgname=${imgname:-${imgrepo}${distro}:${imgtag}-${ARCH}}
podname=${podname:-openbmc${BUILD_ID}-${target}-builder}

# Build the Docker image, using the Dockerfile carried from build-setup.sh
docker build -t ${imgname} - <<< "${Dockerfile}"

# Push the image that was built to the image repository
docker push ${imgname}

if [[ "${launch}" == "pod" ]]; then
  yamlfile=$(cat << EOF
  apiVersion: v1
  kind: Pod
  metadata:
    name: ${podname}
    namespace: ${namespace}
  spec:
    nodeSelector:
      worker: "true"
      arch: ${ARCH}
    volumes:
    - name: home
      persistentVolumeClaim:
        claimName: ${hclaim}
    - name: sscdir
      persistentVolumeClaim:
        claimName: ${sclaim}
    - name: obmccache
      persistentVolumeClaim:
        claimName: ${oclaim}
    hostNetwork: True
    containers:
    - image: ${imgname}
      name: builder
      command: ["${WORKSPACE}/build.sh"]
      workingDir: ${HOME}
      env:
      - name: WORKSPACE
        value: ${WORKSPACE}
      - name: obmcdir
        value: ${obmcdir}
      securityContext:
        capabilities:
          add:
          - SYS_ADMIN
      volumeMounts:
      - name: home
        mountPath: ${HOME}
      - name: sscdir
        mountPath: ${sscdir}
      - name: obmccache
        mountPath: ${ocache}
    imagePullSecrets:
    - name: ${imgplsec}
EOF
)

elif [[ "${launch}" == "job" ]]; then
  yamlfile=$(cat << EOF
  apiVersion: batch/v1
  kind: Job
  metadata:
    name: openbmc${BUILD_ID}-${target}
    namespace: ${namespace}
    labels:
      app: openbmc
      stage: build
  spec:
    template:
      metadata:
        name: ${podname}
        labels:
          target: ${target}
      spec:
        nodeSelector:
          worker: "true"
          arch: ${ARCH}
        volumes:
        - name: home
          persistentVolumeClaim:
            claimName: ${hclaim}
        - name: sscdir
          persistentVolumeClaim:
            claimName: ${sclaim}
        - name: obmccache
          persistentVolumeClaim:
            claimName: ${oclaim}
        restartPolicy: Never
        hostNetwork: True
        containers:
        - image: ${imgname}
          name: builder
          command: ["${WORKSPACE}/build.sh"]
          workingDir: ${HOME}
          env:
          - name: WORKSPACE
            value: ${WORKSPACE}
          - name: obmcdir
            value: ${obmcdir}
          securityContext:
            capabilities:
              add:
              - SYS_ADMIN
          volumeMounts:
          - name: home
            mountPath: ${HOME}
          - name: sscdir
            mountPath: ${sscdir}
          - name: obmccache
            mountPath: ${ocache}
        imagePullSecrets:
        - name: ${imgplsec}
EOF
)
fi

kubectl create -f - <<< "${yamlfile}"

# Wait for Pod to be running before tailing log file
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

# Once pod is running track logs
kubectl logs -f ${podname} -n ${namespace}

# When job is completed wipe the job
kubectl delete -f - <<< "${yamlfile}"