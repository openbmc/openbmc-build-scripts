#!/bin/bash

# This script reformats source files using the clang-format utility.
#
# Files are changed in-place, so make sure you don't have anything open in an
# editor, and you may want to commit before formatting in case of awryness.
#
# This must be run on a clean repository to succeed
#
# Input parmameter must be full path to git repo to scan

DIR=$1
cd ${DIR}

set -e

echo "Formatting code under $DIR/"

if [[ -f "setup.cfg" ]]; then
  pycodestyle --show-source .
  rc=$?
  if [[ ${rc} -ne 0 ]]; then
    exit ${rc}
  fi
fi

# Allow called scripts to know which clang format we are using
export CLANG_FORMAT="clang-format-6.0"
IGNORE_FILE=".clang-ignore"
declare -a IGNORE_LIST

if [[ -f "${IGNORE_FILE}" ]]; then
  readarray -t IGNORE_LIST < "${IGNORE_FILE}"
fi

echo "${IGNORE_LIST[@]}"

ignorepaths=""
ignorefiles=""
# All paths must start with ./ for find's path prune expectation.
pathregex='^\.\/.+$'

for path in "${IGNORE_LIST[@]}"; do
  if [[ "${path}" =~ ^\.\/.+$ ]]; then
    ignorepaths+=" -o -path ${path} -prune"
  else
    ignorefiles+=" -not -name ${path}"
  fi
done

if [[ -f ".clang-format" ]]; then
  find . \( -regextype sed -regex ".*\.[hc]\(pp\)\?" ${ignorepaths} \) \
    -not -name "*mako*" ${ignorefiles} -not -type d -print0 |\
    xargs -0 "${CLANG_FORMAT}" -i
  git --no-pager diff --exit-code
fi

# Sometimes your situation is terrible enough that you need the flexibility.
# For example, phosphor-mboxd.
if [[ -f "format-code.sh" ]]; then
  ./format-code.sh
  git --no-pager diff --exit-code
fi
