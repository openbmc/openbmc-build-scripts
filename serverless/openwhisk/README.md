
This script will atempt to build the latest OpenBMC version on OpenWhisk. It's more for show,
as OpenWhisk will limit builds to 5 minutes long, much shorter than the time needed to build
all of OpenBMC.

1. Download and install the OpenWhisk CLI
2. Run new-build-setup.sh
3. Update or create an OpenWhisk action with the Docker image on DockerHub
4. Run the action via the OpenWhisk CLI

```
# install dockerSkeleton with example
wsk sdk install docker

# set the name of the DockerHub user account to push to
export DOCKERHUB_USER=<your username>

# setup the local directory to be built by Docker
./new-build-setup.sh

# create docker action
wsk action create obmc-build --docker <dockerhub username>/obmc-test

# invoke created action
wsk action invoke obmc-build --blocking
```

When OpenWhisk starts this docker image, it will run the the exec binary in
the /action directory. This binary is a compiled C program (exec.c) that will
run the build script. OpenWhisk expects a binary program rather than a script.

