#!/bin/bash
# bitbake-build.sh - Run a BitBake build inside the target container.
#
# Required environment variables (passed in from the Jenkins pipeline):
#   TARGET      - the MACHINE name (e.g. p10bmc)
#   BUILD_BASE  - absolute path to the openbmc checkout inside the container
#   IMAGE       - the Docker image to run the build in

set -e

JOBS=$(nproc --all | awk '{print int($1/4)}')
[ "$JOBS" -lt 2 ] && JOBS=2

cd "${BUILD_BASE}"
. ./setup "${TARGET}"

echo BB_SIGNATURE_HANDLER = '"OEBasicHash"'                                          >> conf/local.conf
echo SSTATE_MIRRORS       = '"file://.* file:///var/lib/openbmc/sstate-cache/PATH"'  >> conf/local.conf
echo BB_NUMBER_THREADS    = '"'"${JOBS}"'"'                                           >> conf/local.conf
echo PARALLEL_MAKE        = '"-j '"${JOBS}"'"'                                        >> conf/local.conf

MACHINE="${TARGET}" bitbake obmc-phosphor-image
