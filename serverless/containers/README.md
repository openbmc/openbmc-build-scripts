
**Running Open BMC Builds on CLI Containers**

This container will run a build of the latest OpenBMC version using the IBM
Containers service. Before gettings started, you should already have a
Bluemix account. It'd be a good idea to be familiar with IBM Containers
as well.

1. Install the IBM Containers CLI
2. Set proper environment variables (see top of build-setup.sh script)
3. Run ./build-setup.sh
4. Create the container
5. Run the container

Steps 4 and 5 can be done all at once with the command line by doing
something like the following:

cf ic run -p 9080 \
  -e "LOG_LOCATION=/home/baker/build-log.txt" \
  -m 2048 \
  --name cli-build-container \
  --volume <IBM containers account name>:/mnt/<volume name> \
 registry.ng.bluemix.net/<image registry>/obmc-build

This will create and run an IBM Container with the name of cli-build-container
with 2048 megabytes of memory, storing the build products in a volume

