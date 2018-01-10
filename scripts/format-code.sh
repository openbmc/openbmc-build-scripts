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

echo "Formatting code under $DIR/"
find . -regextype sed -regex ".*\.[hc]\(pp\)\?" -not -name "*mako*" -print0 | xargs -0 "clang-format-3.9" -i

git --no-pager diff --exit-code
