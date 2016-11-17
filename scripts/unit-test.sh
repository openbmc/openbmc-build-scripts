#!/bin/bash -xe
#
# Execute the given repository's unit tests
#
set -o pipefail

WORKSPACE=${WORKSPACE:-${HOME}}

# Go into repository to be tested
cd ${WORKSPACE}

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

# Cleanup workspace
rm -rf ./*
