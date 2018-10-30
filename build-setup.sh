#!/bin/bash
###############################################################################
#
# This build script is for running the OpenBMC builds as containers with the
# option of launching the containers with Docker or Kubernetes.
#
###############################################################################
# Trace bash processing. Set -e so when a step fails, we fail the build
set -xeo pipefail

build_scripts_dir=${build_scripts_dir:-"$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}

$("${build_scripts_dir}/build-bitbake-docker.sh")
$("${build_scripts_dir}/run-bitbake-docker.sh")
