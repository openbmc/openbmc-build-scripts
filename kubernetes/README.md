Running OpenBMC Builds on Kubernetes
=====================================
To do a run of an OpenBMC build in the Kubernetes cloud it is a good idea to understand containers and to get some
understanding of Kubernetes. Kubernetes clusters can be created on most cloud service providers and are currently in beta on Bluemix. They can also exist as VM's and Bare Metal machines.

Steps required to do an OpenBMC build on Kubernetes:
1. Obtain Access to a Kubernetes Cluster
2. Install Kubectl to the machine you are running the script from
3. Login/Configure the Kubectl to connect to your cluster
4. Ensure NFS mount exists for the build container to use. (see [./storage-setup.sh](https://github.com/openbmc/openbmc-build-scripts/kubernetes/storage-setup.sh)) Best to mount one directory and have one subdirectory for work and another for shared-state cache.
5. Run the [./build-setup.sh](https://github.com/openbmc/openbmc-build-scripts/kubernetes/storage-setup.sh) to launch the build container as a Kubernetes job
6. Stream the log using "kubectl logs -f ${Name of Pod}"

## Useful links:
Kubernetes (K8s) is an open source container orchestration system.
- [Kubernetes Repo](https://github.com/kubernetes/kubernetes)

If you would like to know more regarding Kubernetes look over these:
- [Concepts](https://kubernetes.io/docs/concepts/)
- [API Documentation v1.5](https://kubernetes.io/docs/api-reference/v1.5/)
- [API Documentation v1.6](https://kubernetes.io/docs/api-reference/v1.6/)

## Persistent Data Storage
Since Kubernetes works using various nodes to run the builds it is best to use NFS or GlusterFS storage so that data will not be bound to one machine directly. This lets us not care about what node is currently running the container while maintaining access to the data we want.

PVs and PVCs are the way Kubernetes Mounts directories to containers. A script used to launch an NFS mount PV and PVC pair can be found [here](https://github.com/openbmc/openbmc-build-scripts/kubernetes/storage-setup.sh "Storage Setup Script") . There is one caveat to using external storage mounts, the folders used to do the actual build cannot be mounted to an external file system.
- [Persitent Volume (pv)](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#persistent-volumes)
- [Persistent Volume Claim (pvc)](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#persistentvolumeclaims)

