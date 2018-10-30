#!/bin/bash

DIR=$1
cd ${DIR}

set -ex

echo "Formatting code under $DIR/"

export CLANG_TIDY="clang-tidy-6.0"
IGNORE_FILE=".clang-ignore"
declare -a IGNORE_LIST

# TODO: move common code into single source.
if [[ -f "${IGNORE_FILE}" ]]; then
  readarray -t IGNORE_LIST < "${IGNORE_FILE}"
fi

ignorepaths=""
ignorefiles=""

for path in "${IGNORE_LIST[@]}"; do
  # Check for comment, line starting with space, or zero-length string.
  # Checking for [[:space:]] checks all options.
  if [[ -z "${path}" ]] || [[ "${path}" =~ ^(#|[[:space:]]).*$ ]]; then
    continue
  fi

  # All paths must start with ./ for find's path prune expectation.
  if [[ "${path}" =~ ^\.\/.+$ ]]; then
    ignorepaths+=" -o -path ${path} -prune"
  else
    ignorefiles+=" -not -name ${path}"
  fi
done

"${CLANG_TIDY}" --help

if [[ -f ".clang-tidy" ]]; then
  FILES="$(find . \( -regextype sed -regex ".*\.[hc]\(pp\)\?" ${ignorepaths} \) -not -name "*mako*" ${ignorefiles} -not -type d -exec echo -n '{} ' \;| tr '\n' ' ')"

  "${CLANG_TIDY}" -fix-errors ${FILES} -- -I/usr/local/include -I.
  git --no-pager diff --exit-code
fi
