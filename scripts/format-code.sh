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
WORKSPACE=$PWD
WORKSPACE_CONFIG="${WORKSPACE}/openbmc-build-scripts/config"

set -e

echo "Running spelling check on Commit Message"

# Run the codespell with openbmc spcific spellings on the patchset
echo "openbmc-dictionary - misspelling count >> "
sed "s/Signed-off-by.*//" "${DIR}/.git/COMMIT_EDITMSG" | \
    codespell -D "${WORKSPACE_CONFIG}/openbmc-spelling.txt" -d --count -

# Run the codespell with generic dictionary on the patchset
echo "generic-dictionary - misspelling count >> "
sed "s/Signed-off-by.*//" "${DIR}/.git/COMMIT_EDITMSG" | \
    codespell --builtin clear,rare,en-GB_to_en-US -d --count -

# Check for commit message issues
gitlint \
  --target "${DIR}" \
  --extra-path "${WORKSPACE_CONFIG}/gitlint/" \
  --config "${WORKSPACE_CONFIG}/.gitlint"

cd "${DIR}"

echo "Formatting code under $DIR/"

if [[ -f ".eslintignore" ]]; then
  ESLINT_IGNORE="--ignore-path .eslintignore"
elif [[ -f ".gitignore" ]]; then
  ESLINT_IGNORE="--ignore-path .gitignore"
fi

# Get the eslint configuration from the repository
if [[ -f ".eslintrc.json" ]]; then
    echo "Running the json validator on the repo using it's config > "
    ESLINT_RC="-c .eslintrc.json"
else
    echo "Running the json validator on the repo using the global config"
    ESLINT_RC="--no-eslintrc -c ${WORKSPACE_CONFIG}/eslint-global-config.json"
fi

ESLINT_COMMAND="eslint . ${ESLINT_IGNORE} ${ESLINT_RC} \
               --ext .json --format=stylish \
               --resolve-plugins-relative-to /usr/local/lib/node_modules \
               --no-error-on-unmatched-pattern"

# Print eslint command
echo "$ESLINT_COMMAND"
# Run eslint
$ESLINT_COMMAND

if [[ -f "setup.cfg" ]]; then
  pycodestyle --show-source --exclude=subprojects .
  rc=$?
  if [[ ${rc} -ne 0 ]]; then
    exit ${rc}
  fi
fi

# If .shellcheck exists, stop on error.  Otherwise, allow pass.
if [[ -f ".shellcheck" ]]; then
  shellcheck_allowfail="false"
else
  shellcheck_allowfail="true"
fi

# Run shellcheck on any shell-script.
shell_scripts="$(git ls-files | xargs -n1 file -0 | \
                 grep -a "shell script" | cut -d '' -f 1)"
for script in ${shell_scripts}; do
  shellcheck --color=never -x "${script}" || ${shellcheck_allowfail}
done

# Allow called scripts to know which clang format we are using
export CLANG_FORMAT="clang-format"
IGNORE_FILE=".clang-ignore"
declare -a IGNORE_LIST

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
    ignorepaths+=" ${path}"
  else
    ignorefiles+=" ${path}"
  fi
done

searchfiles=""
while read -r path; do
  # skip ignorefiles
  if [[ $ignorefiles == *"$(basename "${path}")"* ]]; then
    continue
  fi

  skip=false
  #skip paths in ingorepaths
  for pathname in $ignorepaths; do
    if [[ "./${path}" == "${pathname}"* ]]; then
       skip=true
       break
    fi
  done

  if [ "$skip" = true ]; then
   continue
  fi
  # shellcheck disable=2089
  searchfiles+="\"./${path}\" "

# Get C and C++ files managed by git and skip the mako files
done <<<"$(git ls-files | grep -e '\.[ch]pp$' -e '\.[ch]$' | grep -v '\.mako\.')"

if [[ -f ".clang-format" ]]; then
  # shellcheck disable=SC2090 disable=SC2086
  echo ${searchfiles} | xargs "${CLANG_FORMAT}" -i
  git --no-pager diff --exit-code
fi

# Sometimes your situation is terrible enough that you need the flexibility.
# For example, phosphor-mboxd.
if [[ -f "format-code.sh" ]]; then
  ./format-code.sh
  git --no-pager diff --exit-code
fi
