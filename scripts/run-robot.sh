#!/bin/bash -x
# Extract and run the OpenBMC robot test suite
#
# The robot test results will be copied to ${HOME}
#
#  Requires following env variables be set:
#   IP_ADDR     IP Address of openbmc
#   SSH_PORT    SSH port of openbmc
#   HTTPS_PORT  HTTPS port of openbmc
#
#  Optional env variable
#   ROBOT_CODE_HOME  Location to extract the code
#                    Default will be a temp location in /tmp/
#   ROBOT_TEST_CMD   Command to execute from within obmc robot test framework
#                    Default will be "tox -e qemux86-64 -- --include QEMU_CI tests"
#   MACHINE          Type of system to run tests against
#                    Default is qemux86-64

# we don't want to fail on bad rc since robot tests may fail

MACHINE=${MACHINE:-"qemux86-64"}
ROBOT_CODE_HOME=${ROBOT_CODE_HOME:-/tmp/$(whoami)/${RANDOM}/obmc-robot/}
ROBOT_TEST_CMD=${ROBOT_TEST_CMD:-"tox -e ${MACHINE} -- --argumentfile test_lists/QEMU_CI tests"}

git clone https://github.com/openbmc/openbmc-test-automation.git \
        ${ROBOT_CODE_HOME}

cd ${ROBOT_CODE_HOME}

chmod ugo+rw -R ${ROBOT_CODE_HOME}/*

# Execute the CI tests
export OPENBMC_HOST=${IP_ADDR}
export SSH_PORT=${SSH_PORT}
export HTTPS_PORT=${HTTPS_PORT}

"$($ROBOT_TEST_CMD)"

cp ${ROBOT_CODE_HOME}/*.xml ${HOME}/
cp ${ROBOT_CODE_HOME}/*.html ${HOME}/
if [ -d logs ] ; then
    cp -Rf ${ROBOT_CODE_HOME}/logs ${HOME}/ ;
fi

#rm -rf ${ROBOT_CODE_HOME}
