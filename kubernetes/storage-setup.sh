#!/bin/bash
###############################################################################
#
# This script creates an NFS Persistent Volumes(PV) and also claims that PV
# with a PVC of the same size.
# Note: PVs can be claimed by one PVC at a time
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
# The script expects a few variables which are needed to define PV's and PVC's
#  ns      = Namespace under which to create the mounts on the cluster
#  nfsip   = Server IP for NFS server that will be used
#  nfspath = Path of the directory that will be mounted from NFS server
#  size    = The size of the volume, numeric value followed by Gi or Mi
#  name    = The name of the PV and PVC that will be used by the Kubernetes
#            system to refer to PV/PVC
#  mode    = ReadWriteOnce|ReadOnlyMany|ReadWriteMany
#            Access Mode used by NFS normally uses ReadWriteMany
#  reclaim = recycle|delete|retain
#            The policy, defines what occurs when claim on PV is released, can
#            be either: recycle, delete, or retain.
#
# Note: Kubernetes Systems permissions vary by implementation
#       some will require permissions to create PV's or PVC's
#
###############################################################################

ns=${ns:-openbmc}
nfsip=${nfsip:-NFS-Server}
nfspath=${nfspath:-/san/dir}
size=${size:-10Gi}
name=${name:-placeholder}
mode=${mode:-ReadWriteMany}
reclaim=${reclaim:-Retain}

# Generate the PV
pv=$(cat << EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  labels:
    app: ${name}
  name: ${name}
  namespace: ${ns}
spec:
  accessModes:
  - ${mode}
  capacity:
    storage: ${size}
  nfs:
    path: ${nfspath}
    server: ${nfsip}
  persistentVolumeReclaimPolicy: ${reclaim}
EOF
)

# create the volume
if [ -z $(kubectl get pv --namespace=${ns} | grep '^'${name}' ' | cut -d " " -f1) ];then
  echo "Creating Persistent Volume ${name}"
  kubectl create -f - <<< "${pv}"
else
  echo "Persistent Volume already Exists"
fi


# Generate the PVC
pvc=$(cat << EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  accessModes:
  - ${mode}
  resources:
    requests:
      storage: ${size}
  selector:
    matchLabels:
      app: ${name}
EOF
)

# create PVC's to bind the PV's
if [ -z $(kubectl get pvc --namespace=${ns} | grep '^'${name}' ' | cut -d " " -f1) ];then
  echo "Creating Persistent Volume Claim ${name}"
  kubectl create -f - <<< "${pvc}"
else
  echo "Persistent volume claim already exists."
fi
