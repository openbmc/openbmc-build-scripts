#!/bin/bash -xe
#
# Execute the given repository's unit tests
#
set -o pipefail

TMP=/tmp/
WORKSPACE=${WORKSPACE:-${HOME}}

# Go into repository to be tested
cp -R ${WORKSPACE} ${TMP}
cd ${TMP}

# TEMP? Make sure in a valid repository
if [ -e "bootstrap.sh" ]; then
# Configure package
./bootstrap.sh
./configure ${CONFIGURE_FLAGS}

# Build package
make

# Install package
make install

# Run package unit tests
make check
fi
