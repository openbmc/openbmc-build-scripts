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
if [ -e "configure.ac" ]; then
    # Determine dependencies from configure.ac
    # TODO - Need this functionalized to be called recursively
    while read config; do
      if [[ $config == "AC_CHECK_LIB"* ]]; then
        if [[ $config == *"mapper"* ]]; then
            echo "Install openbmc/phosphor-objmgr"
            cd ${WORKDIR}
            git clone https://github.com/openbmc/phosphor-objmgr.git
            cd ${WORKDIR}/phosphor-objmgr
            ./bootstrap.sh
            ./configure --enable-unpatched-systemd
            make && make install
            cd ${WORKDIR}/${PKG}
        fi
      elif [[ $config == "AC_CHECK_HEADER"* ]]; then
        if [[ $config == *"host-ipmid/ipmid-api.h"* ]]; then
            echo "Install openbmc/phosphor-host-ipmid"
            cd ${WORKDIR}
            git clone https://github.com/openbmc/phosphor-host-ipmid.git
            cd ${WORKDIR}/phosphor-host-ipmid
            ./bootstrap.sh
            ./configure
            make && make install
            cd ${WORKDIR}
        elif [[ $config == *"linux/bt-bmc.h"* ]]; then
            echo "Install uapi linux/bt-bmc.h"
            # Handled within btbridge's configure.ac
        fi
      fi
    done < configure.ac

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
