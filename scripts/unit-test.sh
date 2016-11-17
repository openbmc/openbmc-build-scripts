#!/bin/bash -xe
#
# Execute the given repository's unit tests
#
set -o pipefail

TMP=/tmp
WORKSPACE=${WORKSPACE:-${HOME}}

# Determine package name and change working dir
PKG=$(echo $WORKSPACE|grep -oP '[^/]*$')
WORKDIR=${TMP}/${RANDOM}${RANDOM}/
mkdir -p ${WORKDIR}
cp -R ${WORKSPACE} ${WORKDIR}
cd ${WORKDIR}/${PKG}

# TEMP Make sure in a valid repository
if [ -e "bootstrap.sh" ]; then
    # Configure package
    ./bootstrap.sh
    ./configure

    # Build package
    make

    # Install package
    make install

    #TODO Verify each make directive is run, i.e.) `make docs` ?

    # Run package unit tests
    make check
fi
