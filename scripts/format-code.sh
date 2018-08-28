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

if [ -f "setup.cfg" ]; then
  pycodestyle --show-source .
  rc=$?
  if [ ${rc} -ne 0 ]; then
    exit ${rc}
  fi
fi

if [ -f ".clang-format" ]; then
  find . -regextype sed -regex ".*\.[hc]\(pp\)\?" -not -name "*mako*" -print0 |\
     xargs -0 "clang-format-6.0" -i
  git --no-pager diff --exit-code
fi

# Sometimes your situation is terrible enough that you need the flexibility.
# For example, phosphor-mboxd.
if [ -f "format-code.sh" ]; then
  ./format-code.sh
  git --no-pager diff --exit-code
fi
