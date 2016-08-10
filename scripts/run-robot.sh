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

# we don't want to fail on bad rc since robot tests may fail

ROBOT_CODE_HOME=${ROBOT_CODE_HOME:-/tmp/$(whoami)/${RANDOM}/obmc-robot/}

git clone https://github.com/openbmc/openbmc-test-automation.git \
        ${ROBOT_CODE_HOME}

cd ${ROBOT_CODE_HOME}

chmod ugo+rw -R ${ROBOT_CODE_HOME}/*

# Execute the CI tests
export OPENBMC_HOST=${IP_ADDR}
export SSH_PORT=${SSH_PORT}
export HTTPS_PORT=${HTTPS_PORT}

tox -e qemu -- --include CI tests

cp ${ROBOT_CODE_HOME}/*.xml ${HOME}/
cp ${ROBOT_CODE_HOME}/*.html ${HOME}/

#rm -rf ${ROBOT_CODE_HOME}
