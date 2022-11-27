#!/bin/bash
set -e

# This script reformats source files using various formatters and linters.
#
# Files are changed in-place, so make sure you don't have anything open in an
# editor, and you may want to commit before formatting in case of awryness.
#
# This must be run on a clean repository to succeed
#
function display_help()
{
    echo "usage: format-code.sh [-h | --help] "
    echo "                      [<path>]"
    echo
    echo "Format and lint a repository."
    echo
    echo "Arguments:"
    echo "    path           Path to git repository (default to pwd)"
}

eval set -- "$(getopt -o 'h' --long 'help' -n 'format-code.sh' -- "$@")"
while true; do
    case "$1" in
        '-h'|'--help')
            display_help && exit 0
            ;;

        '--')
            shift
            break
            ;;

        *)
            echo "unknown option: $1"
            display_help && exit 1
            ;;
    esac
done

# Detect tty and set nicer colors.
if [ -t 1 ]; then
    BLUE="\e[34m"
    GREEN="\e[32m"
    NORMAL="\e[0m"
    RED="\e[31m"
    YELLOW="\e[33m"
else # non-tty, no escapes.
    BLUE=""
    GREEN=""
    NORMAL=""
    RED=""
    YELLOW=""
fi

# Path to default config files for linters.
CONFIG_PATH="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)/config"

# Find repository root for `pwd` or $1.
if [ -z "$1" ]; then
    DIR="$(git rev-parse --show-toplevel || pwd)"
else
    DIR="$(git -C "$1" rev-parse --show-toplevel)"
fi
if [ ! -d "$DIR/.git" ]; then
    echo "${RED}Error:${NORMAL} Directory ($DIR) does not appear to be a git repository"
    exit 1
fi

cd "${DIR}"
echo -e "    ${BLUE}Formatting code under${NORMAL} $DIR"

ALL_OPERATIONS=( \
        commit_gitlint \
        commit_spelling \
        clang_format \
        eslint \
        pycodestyle \
        shellcheck \
    )

function do_commit_spelling() {
    if [ ! -e .git/COMMIT_EDITMSG ]; then
        return
    fi
    echo -e "    ${BLUE}Running codespell${NORMAL}"

    # Run the codespell with openbmc spcific spellings on the patchset
    echo "openbmc-dictionary - misspelling count >> "
    sed "s/Signed-off-by.*//" .git/COMMIT_EDITMSG | \
        codespell -D "${CONFIG_PATH}/openbmc-spelling.txt" -d --count -

    # Run the codespell with generic dictionary on the patchset
    echo "generic-dictionary - misspelling count >> "
    sed "s/Signed-off-by.*//" .git/COMMIT_EDITMSG | \
        codespell --builtin clear,rare,en-GB_to_en-US -d --count -
}

function do_commit_gitlint() {
    echo -e "    ${BLUE}Running gitlint${NORMAL}"
    # Check for commit message issues
    gitlint \
        --extra-path "${CONFIG_PATH}/gitlint/" \
        --config "${CONFIG_PATH}/.gitlint"
}

function do_eslint() {
    if [[ -f ".eslintignore" ]]; then
        ESLINT_IGNORE="--ignore-path .eslintignore"
    elif [[ -f ".gitignore" ]]; then
        ESLINT_IGNORE="--ignore-path .gitignore"
    fi

    # Get the eslint configuration from the repository
    if [[ -f ".eslintrc.json" ]]; then
        echo -e "    ${BLUE}Running eslint${NORMAL}"
        ESLINT_RC="-c .eslintrc.json"
    else
        echo -e "    ${BLUE}Running eslint using ${YELLOW}the global config${NORMAL}"
        ESLINT_RC="--no-eslintrc -c ${CONFIG_PATH}/eslint-global-config.json"
    fi

    ESLINT_COMMAND="eslint . ${ESLINT_IGNORE} ${ESLINT_RC} \
               --ext .json --format=stylish \
               --resolve-plugins-relative-to /usr/local/lib/node_modules \
               --no-error-on-unmatched-pattern"

    # Print eslint command
    echo "$ESLINT_COMMAND"
    # Run eslint
    $ESLINT_COMMAND
}

function do_pycodestyle() {
    if [[ -f "setup.cfg" ]]; then
        echo -e "    ${BLUE}Running pycodestyle${NORMAL}"
        pycodestyle --show-source --exclude=subprojects .
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            exit ${rc}
        fi
    fi
}

function do_shellcheck() {
    # If .shellcheck exists, stop on error.  Otherwise, allow pass.
    if [[ -f ".shellcheck" ]]; then
        local shellcheck_allowfail="false"
    else
        local shellcheck_allowfail="true"
    fi

    # Run shellcheck on any shell-script.
    shell_scripts="$(git ls-files | xargs -n1 file -0 | \
    grep -a "shell script" | cut -d '' -f 1)"
    if [ -n "${shell_scripts}" ]; then
        echo -e "    ${BLUE}Running shellcheck${NORMAL}"
    fi
    for script in ${shell_scripts}; do
        shellcheck --color=never -x "${script}" || ${shellcheck_allowfail}
    done
}


do_clang_format() {
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
        echo -e "    ${BLUE}Running clang-format${NORMAL}"
        # shellcheck disable=SC2090 disable=SC2086
        echo ${searchfiles} | xargs "${CLANG_FORMAT}" -i
    fi

}

for op in "${ALL_OPERATIONS[@]}"; do
    "do_$op"
done

echo -e "    ${BLUE}Result differences...${NORMAL}"
if ! git --no-pager diff --exit-code ; then
    echo -e "Format: ${RED}FAILED${NORMAL}"
    exit 1
else
    echo -e "Format: ${GREEN}PASSED${NORMAL}"
fi

# Sometimes your situation is terrible enough that you need the flexibility.
# For example, phosphor-mboxd.
if [[ -f "format-code.sh" ]]; then
    ./format-code.sh
    git --no-pager diff --exit-code
fi
