#!/bin/bash

# Creates a txt file of all src_uri's and src_rev's of the dependencies
# for the current image build. Data is structured in the following format:
# <src_uri> <src_rev>
#
# Script Variables:
#   build_history - Path to the build's build_history's collection of repo packages
#   output_file - Path to where to create the script's output file.
set -e

build_history="$1"
output_file="$2/repositories.txt"

if [[ ! -d "${build_history}" ]]; then
    echo "Path to buildhistory not found"
    exit 1
fi

if [[ -f "${output_file}" ]]; then
    rm -rf "${output_file}"
fi

for repo_dir in "${build_history}"/*;
do
    src_url_file="${repo_dir}/latest"
    src_rev_file="${repo_dir}/latest_srcrev"

    if [[ ! -f "${src_url_file}" ]]; then
        continue
    fi

    url_info="$( tail -n 1 "${src_url_file}" )"
    read -r -a url_arr <<< "${url_info}"
    file_found=false

    for dependency in ${url_arr[2]};
    do
        if [[ "${dependency}" =~ ^"git://github.com/openbmc/".* ]]; then
            src_url="${dependency}"
            file_found=true
        fi
    done

    if [[ "${file_found}" == true ]]; then
        # Get revision if available
        if [[ -f "${src_rev_file}" ]]; then
            rev_info=$( tail -n 1 "${src_rev_file}" )
            read -r -a rev_arr <<< "${rev_info}"
            src_rev="${rev_arr[2]:1:-1}"

            echo "${src_url}" "${src_rev}" >> "${output_file}"
        else
            echo "${src_url}" >> "${output_file}"
        fi
    fi

done