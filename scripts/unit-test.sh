#!/bin/bash -xe
#
# Execute the given repository's unit tests
#
set -uo pipefail

# TEMP - Retrieve package source
git clone https://github.com/openbmc/phosphor-event ${WORKSPACE}/phosphor-event

# Configure package
${WORKSPACE}/phosphor-event/bootstrap.sh
${WORKSPACE}/phosphor-event/configure ${CONFIGURE_FLAGS}

# Build package
${WORKSPACE}/phosphor-event/make

# Install package ?
${WORKSPACE}/phosphor-event/make install

# Run package unit tests
#${WORKSPACE}/phosphor-event/make check
