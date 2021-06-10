#!/bin/bash 
ROOT_DIR="$(pwd)"
BUILDHISTORY="${BUILDDIR}/buildhistory/packages/arm1176jzs-openbmc-linux-gnueabi"
OUTPUT_FILE="${WORKDIR}/dependencies.txt"

if [[ ! -d ${BUILDHISTORY} ]]; then 
    echo "Path to buildhistory not available"
    return 
fi 

if [[ -f ${OUTPUT_FILE} ]]; then 
    rm -rf ${OUTPUT_FILE}
fi 

cd ${BUILDHISTORY}

for REPO_DIR in $(ls); 
do 
    SRC_URL_FILE="${REPO_DIR}/latest"
    SRC_REV_FILE="${REPO_DIR}/latest_srcrev"
    
    if [[ ! -f ${SRC_URL_FILE} ]]; then 
        continue 
    fi 

    URL_INFO=$( tail -n 1 ${SRC_URL_FILE} ) 
    URL_ARR=(${URL_INFO})
    FILEFOUND=false

    for DEPENDENCY in "${URL_ARR[@]:2}";
    do
        if [[ ${DEPENDENCY} =~ ^"git://github.com/openbmc".* ]]; then 
            SRC_URL=${DEPENDENCY}
            FILEFOUND=true
        fi 
    done

    if [[ ${FILEFOUND} == true ]]; then 
        # Get revision if available
        if [[ -f ${SRC_REV_FILE} ]]; then 
            REV_INFO=$( tail -n 1 ${SRC_REV_FILE} ) 
            REV_ARR=(${REV_INFO})
            SRC_REV=${REV_ARR[2]:1:-1}

            echo ${SRC_URL} ${SRC_REV} >> ${OUTPUT_FILE}
        else 
            echo ${SRC_URL} >> ${OUTPUT_FILE}
        fi 
    fi 

done 

cd ${ROOT_DIR}