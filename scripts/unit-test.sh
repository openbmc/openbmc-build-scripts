#!/bin/bash -xe
#
# Execute the given repository's unit tests
#
set -o pipefail

WORKSPACE=${WORKSPACE:-${HOME}}

# TEMP - Retrieve package source
git clone https://github.com/openbmc/phosphor-event ${WORKSPACE}/phosphor-event
cd ${WORKSPACE}/phosphor-event

# Configure package
./bootstrap.sh
./configure ${CONFIGURE_FLAGS}

# Build package
make

# Install package
make install

# Run package unit tests
make check
