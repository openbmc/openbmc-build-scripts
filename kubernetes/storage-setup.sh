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
# It expects a few variables which are for needed to define PV's and PVC's
#  NS      = Namespace under which to create the mounts on the cluster
#  NFSIP   = Server IP for NFS server that will be used
#  NFSPATH = Path of the directory that will be mounted from NFS server
#  SIZE    = The size of the volume, numeric value followed by Gi or Mi
#  NAME    = The name of the PV and PVC that will be used by the Kubernetes
#            system to refer to PV/PVC
#  MODE    = ReadWriteOnce|ReadOnlyMany|ReadWriteMany
#            Access Mode used by NFS normally uses ReadWriteMany
#  RECLAIM = recycle|delete|retain
#            The policy, defines what occurs when claim on PV is released, can
#            be either: recycle, delete, or retain.
#
# Note: Kubernetes Systems permissions vary by implementation
#       some will require permissions to create PV's or PVC's
#
###############################################################################

NS=${NS:-openbmc}
NFSIP=${NFSIP:-NFS-Server}
NFSPATH=${NFSPATH:-/san/dir}
SIZE=${SIZE:-10Gi}
NAME=${NAME:-placeholder}
MODE=${MODE:-ReadWriteMany}
RECLAIM=${RECLAIM:-Retain}

# Generate the PV
pv=$(cat << EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  labels:
    app: ${NS}
  name: ${NAME}
  namespace: ${NS}
spec:
  accessModes:
  - ${MODE}
  capacity:
    storage: ${SIZE}
  nfs:
    path: ${NFSPATH}
    server: ${NFSIP}
  persistentVolumeReclaimPolicy: ${RECLAIM}
EOF
)

# create the volume
if [ -z $(kubectl get pv --namespace=${NS} | grep '^'${NAME}' ' | cut -d " " -f1) ];then
     echo "Creating Persistent Volume ${NAME}"
     kubectl create -f - <<< "${pv}"
else
     echo "Persistent Volume already Exists"
fi


# Generate the PVC
pvc=$(cat << EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${NAME}
  namespace: ${NS}
spec:
  accessModes:
  - ${MODE}
  resources:
    requests:
      storage: ${SIZE}
  selector:
    matchLabels:
      app: ${NS}
EOF
)

# create PVC's to bind the PV's
if [ -z $(kubectl get pvc --namespace=${NS} | grep '^'${NAME}' ' | cut -d " " -f1) ];then
     echo "Creating Persistent Volume Claim ${NAME}"
     kubectl create -f - <<< "${pvc}"
else
     echo "Persistent volume claim already exists."
fi
