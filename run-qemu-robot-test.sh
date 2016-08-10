#!/bin/bash -xe

# This script is for starting QEMU against the input build and running
#  the robot CI test suite against it.
#
#  Parameters:
#   UPSTREAM_WORKSPACE = <required, base dir of QEMU image>
#   WORKSPACE =          <optional, temp dir for robot script>

set -uo pipefail

QEMU_RUN_TIMER=300
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
DOCKER_IMG_NAME="openbmc/ubuntu-robot-qemu"
ROBOT_CODE_HOME=/tmp/obmc-test

cd ${UPSTREAM_WORKSPACE}

# Determine our architecture, ppc64le or the other one
if [ $(uname -m) == "ppc64le" ]; then
    DOCKER_BASE="ppc64le/"
    QEMU_ARCH="ppc64le-linux"
else
    DOCKER_BASE=""
    QEMU_ARCH="x86_64-linux"
fi


################################# docker img # #################################
# Create docker image that can run QEMU and Robot Tests
Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}ubuntu:latest

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && apt-get install -yy \
    debianutils \
    gawk \
    git \
    python \
    python-dev \
    python-setuptools \
    socat \
    texinfo \
    wget \
    gcc \
    libffi-dev \
    libssl-dev \
    xterm \
    mwm \
    ssh \
    vim \
    iputils-ping \
    sudo \
    cpio \
    unzip \
    diffstat \
    expect \
    curl

RUN easy_install \
    tox \
    pip \
    requests

RUN pip install \
    robotframework \
    robotframework-requests \
    robotframework-sshlibrary \
    robotframework-scplibrary

RUN git clone https://github.com/openbmc/openbmc-test-automation.git \
                ${ROBOT_CODE_HOME}

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} \
                ${USER}
USER ${USER}
ENV HOME ${HOME}
RUN /bin/bash
EOF
)

################################# docker img # #################################

# Build above image
docker build -t ${DOCKER_IMG_NAME} - <<< "${Dockerfile}"

################################# boot-qemu.sh #################################
# Create shell script that will launch QEMU
cat > boot-qemu.sh << EOF
#!/bin/bash

# Since this is running in docker, open up the default https and ssh
# ports (22,443)
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
set command "$env(HOME)/boot-qemu.sh"

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
# root in docker required to open up the https/ssh ports
obmc_qemu_docker=$(docker run --detach \
                              --user root \
                              --env HOME=${HOME} \
                              --env QEMU_RUN_TIMER=${QEMU_RUN_TIMER} \
                              --workdir "${HOME}"           \
                              --volume "${UPSTREAM_WORKSPACE}":"${HOME}" \
                              --tty \
                              ${DOCKER_IMG_NAME} ${HOME}/boot-qemu-test.sh)

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
    echo "Waiting for qemu to get to standby (attempt: $attempt)..."
    result=$(docker logs $obmc_qemu_docker)
    if grep -q 'OPENBMC-READY' <<< $result ; then
        echo "QEMU is ready!"
        # Give QEMU a few secs to stablize
        sleep 5
        break
    fi
        sleep 2
done

if [ "$attempt" -eq 0 ]; then
    echo "Timed out waiting for QEMU, exiting"
    exit 1
fi

# Now run the robot test

# Timestamp for job
echo "Robot Test started, $(date)"

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
export OPENBMC_HOST=${DOCKER_QEMU_IP_ADDR}
export SSH_PORT=${DOCKER_SSH_PORT}
export HTTPS_PORT=${DOCKER_HTTPS_PORT}

tox -e qemu -- --include CI tests

cp ${ROBOT_CODE_HOME}/*.xml ${HOME}/
cp ${ROBOT_CODE_HOME}/*.html ${HOME}/

EOF_SCRIPT

################################ robot.sh ######################################
chmod a+x ${DOCKER_ROBOT_SCRIPT}

# Run the docker container to execute the robot test cases
docker run --user root \
           --workdir ${HOME} \
           --volume ${WORKSPACE}:${HOME} \
           --tty \
           ${DOCKER_IMG_NAME} ${HOME}/${DOCKER_ROBOT_SCRIPT}

# Now stop the QEMU docker image
docker stop $obmc_qemu_docker
