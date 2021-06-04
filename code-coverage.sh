#!/bin/bash 

ROOT_DIR="$(pwd)"
DEPENDENCIES_FILE="${BUILDDIR}/dependencies.txt"
LEVEL=1

OUTPUT="testing-output.txt"

if [ -f "${DEPENDENCIES_FILE}" ]; then
    if [ -f ${OUTPUT} ]; then 
        rm -rf ${OUTPUT}
    fi
    touch "${OUTPUT}"

    while read -r line; do
        # Make sure you're at root to start
        cd ${ROOT_DIR}
        IFS=' '; read REPO_NAME SRC_URL SRC_REV <<< "${line}"

        BASE="$(basename "${SRC_URL}" .git)"
        REPO_DIR="${REPO_NAME%%.*}-${LEVEL}"

        # Clone repo and checkout to specific srcrev
        git clone "${SRC_URL}" "${ROOT_DIR}/${REPO_DIR}" && cd "${ROOT_DIR}/${REPO_DIR}" 
        git checkout ${SRC_REV}
        cd ${ROOT_DIR}

        # Run docker script
        WORKSPACE="$(pwd)" UNIT_TEST_PKG="${REPO_DIR}" NO_FORMAT_CODE=1 \
        ./openbmc-build-scripts/run-unit-test-docker.sh

        # Aggregate unit test results if exists under the docker file
        UNIT_TEST_RESULTS="${REPO_DIR}/build/meson-logs/coveragereport"
        if [ -d ${UNIT_TEST_RESULTS} ]; then 
            echo "${REPO_DIR}" >> "${OUTPUT}"
            # Run python script to aggregate data
        fi

        let "LEVEL+=1"
    done < "${DEPENDENCIES_FILE}"

fi
