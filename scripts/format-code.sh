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
    echo "usage: format-code.sh [-h | --help] [--no-diff]"
    echo "                      [<path>]"
    echo
    echo "Format and lint a repository."
    echo
    echo "Arguments:"
    echo "    --no-diff      Don't show final diff output"
    echo "    path           Path to git repository (default to pwd)"
}

eval set -- "$(getopt -o 'h' --long 'help,no-diff' -n 'format-code.sh' -- "$@")"
while true; do
    case "$1" in
        '-h'|'--help')
            display_help && exit 0
            ;;

        '--no-diff')
            OPTION_NO_DIFF=1
            shift
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

# Allow called scripts to know which clang format we are using
export CLANG_FORMAT="clang-format"

# Path to default config files for linters.
CONFIG_PATH="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)/config"

# Find repository root for `pwd` or $1.
if [ -z "$1" ]; then
    DIR="$(git rev-parse --show-toplevel || pwd)"
else
    DIR="$(git -C "$1" rev-parse --show-toplevel)"
fi
if [ ! -e "$DIR/.git" ]; then
    echo -e "${RED}Error:${NORMAL} Directory ($DIR) does not appear to be a git repository"
    exit 1
fi

cd "${DIR}"
echo -e "    ${BLUE}Formatting code under${NORMAL} $DIR"

LINTERS_ALL=( \
        commit_gitlint \
        commit_spelling \
        clang_format \
        eslint \
        pycodestyle \
        shellcheck \
    )
declare -A LINTER_REQUIRE=()
declare -A LINTER_CONFIG=()
LINTERS_ENABLED=()

LINTER_REQUIRE+=([commit_spelling]="codespell")
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

LINTER_REQUIRE+=([commit_gitlint]="gitlint")
function do_commit_gitlint() {
    echo -e "    ${BLUE}Running gitlint${NORMAL}"
    # Check for commit message issues
    gitlint \
        --extra-path "${CONFIG_PATH}/gitlint/" \
        --config "${CONFIG_PATH}/.gitlint"
}

LINTER_REQUIRE+=([eslint]="eslint;.eslintrc.json;${CONFIG_PATH}/eslint-global-config.json")
function do_eslint() {
    echo -e "    ${BLUE}Running eslint${NORMAL}"

    if [[ -f ".eslintignore" ]]; then
        ESLINT_IGNORE="--ignore-path=.eslintignore"
    elif [[ -f ".gitignore" ]]; then
        ESLINT_IGNORE="--ignore-path=.gitignore"
    fi

    eslint . "${ESLINT_IGNORE}" --no-eslintrc -c "${LINTER_CONFIG[eslint]}" \
        --ext .json --format=stylish \
        --resolve-plugins-relative-to /usr/local/lib/node_modules \
        --no-error-on-unmatched-pattern
}

LINTER_REQUIRE+=([pycodestyle]="pycodestyle;setup.cfg")
function do_pycodestyle() {
    echo -e "    ${BLUE}Running pycodestyle${NORMAL}"
    pycodestyle --show-source --exclude=subprojects .
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        exit ${rc}
    fi
}

LINTER_REQUIRE+=([shellcheck]="shellcheck;.shellcheck")
function do_shellcheck() {
    # Run shellcheck on any shell-script.
    shell_scripts="$(git ls-files | xargs -n1 file -0 | \
    grep -a "shell script" | cut -d '' -f 1)"
    if [ -n "${shell_scripts}" ]; then
        echo -e "    ${BLUE}Running shellcheck${NORMAL}"
    fi
    for script in ${shell_scripts}; do
        shellcheck --color=never -x "${script}"
    done
}

LINTER_REQUIRE+=([clang_format]="clang-format;.clang-format")
do_clang_format() {

    echo -e "    ${BLUE}Running clang-format${NORMAL}"
    files=$(git ls-files | \
        grep -e '\.[ch]pp$' -e '\.[ch]$' | \
        grep -v '\.mako\.')

    if [ -e .clang-ignore ]; then
        files=$("${CONFIG_PATH}/lib/ignore-filter" .clang-ignore <<< "${files}")
    fi

    xargs "${CLANG_FORMAT}" -i <<< "${files}"
}

function check_linter()
{
    TITLE="$1"
    IFS=";" read -r -a ARGS <<< "$2"

    EXE="${ARGS[0]}"
    if [ ! -x "${EXE}" ]; then
        if ! which "${EXE}" > /dev/null 2>&1 ; then
            echo -e "    ${YELLOW}${TITLE}:${NORMAL} cannot find ${EXE}"
            return
        fi
    fi

    CONFIG="${ARGS[1]}"
    FALLBACK="${ARGS[2]}"

    if [ -n "${CONFIG}" ]; then
        if [ -e "${CONFIG}" ]; then
            LINTER_CONFIG+=( [${TITLE}]="${CONFIG}" )
        elif [ -n "${FALLBACK}" ] && [ -e "${FALLBACK}" ]; then
            echo -e "    ${YELLOW}${TITLE}:${NORMAL} cannot find ${CONFIG}; using ${FALLBACK}"
            LINTER_CONFIG+=( [${TITLE}]="${FALLBACK}" )
        else
            echo -e "    ${YELLOW}${TITLE}:${NORMAL} cannot find config ${CONFIG}"
            return
        fi
    fi

    LINTERS_ENABLED+=( "${TITLE}" )
}

for op in "${LINTERS_ALL[@]}"; do
    check_linter "$op" "${LINTER_REQUIRE[${op}]}"
done

for op in "${LINTERS_ENABLED[@]}"; do
    "do_$op"
done

if [ -z "$OPTION_NO_DIFF" ]; then
    echo -e "    ${BLUE}Result differences...${NORMAL}"
    if ! git --no-pager diff --exit-code ; then
        echo -e "Format: ${RED}FAILED${NORMAL}"
        exit 1
    else
        echo -e "Format: ${GREEN}PASSED${NORMAL}"
    fi
fi

# Sometimes your situation is terrible enough that you need the flexibility.
# For example, phosphor-mboxd.
for formatter in "format-code.sh" "format-code"; do
    if [[ -x "${formatter}" ]]; then
        echo -e "    ${BLUE}Calling secondary formatter:${NORMAL} ${formatter}"
        "./${formatter}"
        if [ -z "$OPTION_NO_DIFF" ]; then
            git --no-pager diff --exit-code
        fi
    fi
done
