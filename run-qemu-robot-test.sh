#!/bin/bash -xe

# This script is for starting QEMU against the input build and running
#  the robot CI test suite against it.
#
# It requires the following as input and should point to the base
#  directory of the QEMU image to be tested:
#   UPSTREAM_WORKSPACE = 

DOCKER_USERID=openbmc
DOCKER_HOME=/home/${DOCKER_USERID}
QEMU_RUN_TIMER=300
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}

cd ${UPSTREAM_WORKSPACE}

# Determine our architecture, ppc64le or the other one
arch=`uname -a`
if grep -q 'ppc64le' <<< $arch ; then
    DOCKER_IMG="geissonator/ubuntu-openbmc-dev-test-ppc64le:latest"
    QEMU_ARCH="ppc64le-linux"
else
    DOCKER_IMG="geissonator/ubuntu-openbmc-dev-test-x86:latest" 
    QEMU_ARCH="x86_64-linux"
fi

# Ensure we have latest version of docker image
docker pull ${DOCKER_IMG}

################################# boot-qemu.sh #################################
# Create shell script that will launch QEMU
cat > boot-qemu.sh << EOF
#!/bin/bash

# Since this is running in docker, open up the default https and ssh ports (22,443)
# They will be appropriately forwarded when the docker image is started
./tmp/sysroots/${QEMU_ARCH}/usr/bin/qemu-system-arm -nographic -kernel \
  ./tmp/deploy/images/qemuarm/zImage-qemuarm.bin -M versatilepb \
  -drive file=./tmp/deploy/images/qemuarm/obmc-phosphor-image-qemuarm.ext4,format=raw \
  -no-reboot -show-cursor -usb -usbdevice wacom-tablet -no-reboot -m 128 \
  -redir tcp:22::22 -redir tcp:443::443 --append \
  "root=/dev/sda rw console=ttyAMA0,115200 console=tty mem=128M highres=off \
  rootfstype=ext4 console=ttyS0"

EOF

################################# boot-qemu.sh #################################
chmod a+x boot-qemu.sh


############################ boot-qemu-test.sh #################################
# Create script that will call the QEMU launch script and ensure it
# gets to a stable login state
cat > boot-qemu-test.sh << \EOF
#!/usr/bin/expect

set timeout "$env(QEMU_RUN_TIMER)*2"
set command "$env(DOCKER_HOME)/boot-qemu.sh"

spawn $command

expect {
  timeout { send_user "\nFailed to boot\n"; exit 1 }
  eof { send_user "\nFailure, got EOF"; exit 1 }
  "qemuarm login:"
}

send "root\r"

expect {
  timeout { send_user "\nFailed, no login prompt\n"; exit 1 }
  eof { send_user "\nFailure, got EOF"; exit 1 }
  "Password:"
}

send "0penBmc\r"

expect {
  timeout { send_user "\nFailed, could not login\n"; exit 1 }
  eof { send_user "\nFailure, got EOF"; exit 1 }
  "root@qemuarm:~#"
}

send_user "OPENBMC-READY\n"
sleep "$env(QEMU_RUN_TIMER)"
send_user "OPENBMC-EXITING\n"

EOF

############################ boot-qemu-test.sh #################################
chmod a+x ./boot-qemu-test.sh

# Start QEMU docker instance
# All docker to assign random host forwarding ports
obmc_qemu_docker=`docker run -d -e DOCKER_HOME=${DOCKER_HOME} -e \
  QEMU_RUN_TIMER=${QEMU_RUN_TIMER}  -w "${DOCKER_HOME}"          \
  -v "${UPSTREAM_WORKSPACE}":"${DOCKER_HOME}"                    \
  -t ${DOCKER_IMG} ${DOCKER_HOME}/boot-qemu-test.sh`

# We can use default ports because we're going to have the 2
# docker instances talk over their private network
DOCKER_SSH_PORT=22
DOCKER_HTTPS_PORT=443
DOCKER_QEMU_IP_ADDR="$(docker inspect $obmc_qemu_docker |  \
                      grep -m 1 "IPAddress\":" | cut -d '"' -f 4)"

# Now wait for the openbmc qemu docker instance to get to standby
attempt=60
while [ $attempt -gt 0 ]; do
    attempt=$(( $attempt - 1 ))
    echo "Waiting for qemu to get to standby (timer: $attempt)..."
    result=$(docker logs $obmc_qemu_docker)
    if grep -q 'OPENBMC-READY' <<< $result ; then
        echo "QEMU is ready!"
        break
    fi
        sleep 2
done

# Now run the robot test

# Timestamp for job
echo "Robot Test started, $(date)"

ROBOT_CODE_HOME=/tmp/obmc-test
DOCKER_ROBOT_SCRIPT=robot.sh

mkdir -p ${WORKSPACE}
cd ${WORKSPACE}

################################ robot.sh ######################################
# Create script to run within the docker image #
cat > "${DOCKER_ROBOT_SCRIPT}" << EOF_SCRIPT
#!/bin/bash

# we don't want to fail on bad rc since robot tests may fail

cd ${ROBOT_CODE_HOME}

# Update robot test code
git reset --hard HEAD && git pull

chmod ugo+rw -R ${ROBOT_CODE_HOME}/*

# Execute the CI tests
export OPENBMC_HOST=${DOCKER_QEMU_IP_ADDR} && export SSH_PORT=${DOCKER_SSH_PORT} && \
  export HTTPS_PORT=${DOCKER_HTTPS_PORT}
tox -e qemu -- --include CI tests

cp ${ROBOT_CODE_HOME}/*.xml ${DOCKER_HOME}/
cp ${ROBOT_CODE_HOME}/*.html ${DOCKER_HOME}/

EOF_SCRIPT

################################ robot.sh ######################################
chmod a+x ${DOCKER_ROBOT_SCRIPT}

# Run the docker container to execute the robot test cases
docker run -w "${DOCKER_HOME}" -v "${WORKSPACE}":"${DOCKER_HOME}" \
  -t ${DOCKER_IMG} ${DOCKER_HOME}/${DOCKER_ROBOT_SCRIPT}
  
# Now stop the QEMU docker image
docker stop $obmc_qemu_docker
