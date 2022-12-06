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
    echo "usage: format-code.sh [-h | --help] [--no-diff] [--list-tools]"
    echo "                      [--disable <tool>] [--enable <tool>] [<path>]"
    echo
    echo "Format and lint a repository."
    echo
    echo "Arguments:"
    echo "    --list-tools      Display available linters and formatters"
    echo "    --no-diff         Don't show final diff output"
    echo "    --disable <tool>  Disable linter"
    echo "    --enable <tool>   Enable only specific linters"
    echo "    --allow-missing   Run even if linters are not all present"
    echo "    path              Path to git repository (default to pwd)"
}

LINTERS_ALL=( \
        commit_gitlint \
        commit_spelling \
        beautysh \
        beautysh_sh \
        black \
        clang_format \
        eslint \
        flake8 \
        isort \
        markdownlint \
        prettier \
        shellcheck \
    )
LINTERS_DISABLED=()
LINTERS_ENABLED=()
declare -A LINTERS_FAILED=()

eval set -- "$(getopt -o 'h' --long 'help,list-tools,no-diff,disable:,enable:,allow-missing' -n 'format-code.sh' -- "$@")"
while true; do
    case "$1" in
        '-h'|'--help')
            display_help && exit 0
            ;;

        '--list-tools')
            echo "Available tools:"
            for t in "${LINTERS_ALL[@]}"; do
                echo "    $t"
            done
            exit 0
            ;;

        '--no-diff')
            OPTION_NO_DIFF=1
            shift
            ;;

        '--disable')
            LINTERS_DISABLED+=("$2")
            shift && shift
            ;;

        '--enable')
            LINTERS_ENABLED+=("$2")
            shift && shift
            ;;

        '--allow-missing')
            ALLOW_MISSING=yes
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

# Config hashes:
#   LINTER_REQUIRE - The requirements to run a linter, semi-colon separated.
#       1. Executable.
#       2. [optional] Configuration file.
#       3. [optional] Global fallback configuration file.
#
#   LINTER_IGNORE - An optional set of semi-colon separated ignore-files
#       specific to the linter.
#
#   LINTER_TYPES - The file types supported by the linter, semi-colon separated.
#
#   LINTER_CONFIG - The config (from LINTER_REQUIRE) chosen for the repository.
#
declare -A LINTER_REQUIRE=()
declare -A LINTER_IGNORE=()
declare -A LINTER_TYPES=()
declare -A LINTER_CONFIG=()

LINTER_REQUIRE+=([commit_spelling]="codespell")
LINTER_TYPES+=([commit_spelling]="commit")
function do_commit_spelling() {
    # Run the codespell with openbmc spcific spellings on the patchset
    echo -n "openbmc-dictionary - misspelling count >> "
    sed "s/Signed-off-by.*//" "$@" | \
        codespell -D "${CONFIG_PATH}/openbmc-spelling.txt" -d --count -

    # Run the codespell with generic dictionary on the patchset
    echo -n "generic-dictionary - misspelling count >> "
    sed "s/Signed-off-by.*//" "$@" | \
        codespell --builtin clear,rare,en-GB_to_en-US -d --count -
}

LINTER_REQUIRE+=([commit_gitlint]="gitlint")
LINTER_TYPES+=([commit_gitlint]="commit")
function do_commit_gitlint() {
    gitlint --extra-path "${CONFIG_PATH}/gitlint/" \
        --config "${CONFIG_PATH}/.gitlint"
}

# We need different function style for bash/zsh vs plain sh, so beautysh is
# split into two linters.  "function foo()" is not traditionally accepted
# POSIX-shell syntax, so shellcheck barfs on it.
LINTER_REQUIRE+=([beautysh]="beautysh")
LINTER_IGNORE+=([beautysh]=".beautysh-ignore")
LINTER_TYPES+=([beautysh]="bash;zsh")
function do_beautysh() {
    beautysh --force-function-style fnpar "$@"
}
LINTER_REQUIRE+=([beautysh_sh]="beautysh")
LINTER_IGNORE+=([beautysh_sh]=".beautysh-ignore")
LINTER_TYPES+=([beautysh_sh]="sh")
function do_beautysh_sh() {
    beautysh --force-function-style paronly "$@"
}

LINTER_REQUIRE+=([black]="black")
LINTER_TYPES+=([black]="python")
function do_black() {
    black -l 79 --preview "$@"
}

LINTER_REQUIRE+=([eslint]="eslint;.eslintrc.json;${CONFIG_PATH}/eslint-global-config.json")
LINTER_IGNORE+=([eslint]=".eslintignore")
LINTER_TYPES+=([eslint]="json")
function do_eslint() {
    eslint --no-eslintrc -c "${LINTER_CONFIG[eslint]}" \
        --ext .json --format=stylish \
        --resolve-plugins-relative-to /usr/local/lib/node_modules \
        --no-error-on-unmatched-pattern "$@"
}

LINTER_REQUIRE+=([flake8]="flake8")
LINTER_IGNORE+=([flake8]=".flake8-ignore")
LINTER_TYPES+=([flake8]="python")
function do_flake8() {
    flake8 --show-source --extend-ignore=E203,E501 "$@"
    # We disable E203 and E501 because 'black' is handling these and they
    # disagree on best practices.
}

LINTER_REQUIRE+=([isort]="isort")
LINTER_TYPES+=([isort]="python")
function do_isort() {
    isort --profile black "$@"
}

LINTER_REQUIRE+=([markdownlint]="markdownlint;.markdownlint.yaml;${CONFIG_PATH}/markdownlint.yaml")
LINTER_IGNORE+=([markdownlint]=".markdownlint-ignore")
LINTER_TYPES+=([markdownlint]="markdown")
function do_markdownlint() {
    markdownlint --config "${LINTER_CONFIG[markdownlint]}" \
        --disable line-length -- "$@" || \
        echo -e "    ${YELLOW}Failed markdownlint; temporarily ignoring."
    # We disable line-length because prettier should handle prose wrap for us.
}

LINTER_REQUIRE+=([prettier]="prettier;.prettierrc.yaml;${CONFIG_PATH}/prettierrc.yaml")
LINTER_IGNORE+=([prettier]=".prettierignore")
LINTER_TYPES+=([prettier]="json;markdown;yaml")
function do_prettier() {
    prettier --config "${LINTER_CONFIG[prettier]}" --write "$@"
}

LINTER_REQUIRE+=([shellcheck]="shellcheck")
LINTER_IGNORE+=([shellcheck]=".shellcheck-ignore")
LINTER_TYPES+=([shellcheck]="bash;sh")
function do_shellcheck() {
    shellcheck --color=never -x "$@"
}

LINTER_REQUIRE+=([clang_format]="clang-format;.clang-format")
LINTER_IGNORE+=([clang_format]=".clang-ignore;.clang-format-ignore")
LINTER_TYPES+=([clang_format]="c;cpp")
function do_clang_format() {
    "${CLANG_FORMAT}" -i "$@"
}

function get_file_type()
{
    case "$(basename "$1")" in
            # First to early detect template files.
        *.in | *.meson) echo "meson-template" && return ;;
        *.mako | *.mako.*) echo "mako" && return ;;

        *.ac) echo "autoconf" && return ;;
        *.[ch]) echo "c" && return ;;
        *.[ch]pp) echo "cpp" &&  return ;;
        *.json) echo "json" && return ;;
        *.md) echo "markdown" && return ;;
        *.py) echo "python" && return ;;
        *.tcl) echo "tcl" && return ;;
        *.yaml | *.yml) echo "yaml" && return ;;

            # Special files.
        .git/COMMIT_EDITMSG) echo "commit" && return ;;
        meson.build) echo "meson" && return ;;
    esac

    case "$(file "$1")" in
        *Bourne-Again\ shell*) echo "bash" && return ;;
        *C++\ source*) echo "cpp" && return ;;
        *C\ source*) echo "c" && return ;;
        *JSON\ data*) echo "json" && return ;;
        *POSIX\ shell*) echo "sh" && return ;;
        *Python\ script*) echo "python" && return ;;
        *python3\ script*) echo "python" && return ;;
        *zsh\ shell*) echo "zsh" && return ;;
    esac

    echo "unknown"
}

LINTERS_AVAILABLE=()
function check_linter()
{
    TITLE="$1"
    IFS=";" read -r -a ARGS <<< "$2"

    if [[ "${LINTERS_DISABLED[*]}" =~ $1 ]]; then
        return
    fi

    if [ 0 -ne "${#LINTERS_ENABLED[@]}" ]; then
        if ! [[ "${LINTERS_ENABLED[*]}" =~ $1 ]]; then
            return
        fi
    fi

    EXE="${ARGS[0]}"
    if [ ! -x "${EXE}" ]; then
        if ! which "${EXE}" > /dev/null 2>&1 ; then
            echo -e "    ${YELLOW}${TITLE}:${NORMAL} cannot find ${EXE}"
            if [ -z "$ALLOW_MISSING" ]; then
                exit 1
            fi
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

    LINTERS_AVAILABLE+=( "${TITLE}" )
}

# Check for a global .linter-ignore file.
GLOBAL_IGNORE=("cat")
if [ -e ".linter-ignore" ]; then
    GLOBAL_IGNORE=("${CONFIG_PATH}/lib/ignore-filter" ".linter-ignore")
fi

# Find all the files in the git repository and organize by type.
declare -A FILES=()
if [ -e .git/COMMIT_EDITMSG ]; then
    FILES+=([commit]=".git/COMMIT_EDITMSG")
fi
while read -r file; do
    ftype="$(get_file_type "$file")"
    FILES+=([$ftype]="$(echo -ne "$file;${FILES[$ftype]:-}")")
done < <(git ls-files | "${GLOBAL_IGNORE[@]}")

# For each linter, check if there are an applicable files and if it can
# be enabled.
for op in "${LINTERS_ALL[@]}"; do
    for ftype in ${LINTER_TYPES[$op]//;/ }; do
        if [[ -v FILES["$ftype"] ]]; then
            check_linter "$op" "${LINTER_REQUIRE[${op}]}"
            break
        fi
    done
done

# Call each linter.
for op in "${LINTERS_AVAILABLE[@]}"; do

    # Determine the linter-specific ignore file(s).
    LOCAL_IGNORE=("${CONFIG_PATH}/lib/ignore-filter")
    if [[ -v LINTER_IGNORE["$op"] ]]; then
        for ignorefile in ${LINTER_IGNORE["$op"]//;/ } ; do
            if [ -e "$ignorefile" ]; then
                LOCAL_IGNORE+=("$ignorefile")
            fi
        done
    fi
    if [ 1 -eq ${#LOCAL_IGNORE[@]} ]; then
        LOCAL_IGNORE=("cat")
    fi

    # Find all the files for this linter, filtering out the ignores.
    LINTER_FILES=()
    while read -r file ; do
        if [ -e "$file" ]; then
            LINTER_FILES+=("$file")
        fi
        done < <(for ftype in ${LINTER_TYPES[$op]//;/ }; do
            # shellcheck disable=SC2001
            echo "${FILES["$ftype"]:-}" | sed "s/;/\\n/g"
    done | "${LOCAL_IGNORE[@]}")

    # Call the linter now with all the files.
    if [ 0 -ne ${#LINTER_FILES[@]} ]; then
        echo -e "    ${BLUE}Running $op${NORMAL}"
        if ! "do_$op" "${LINTER_FILES[@]}" ; then
            LINTERS_FAILED+=([$op]=1)
        fi
    else
        echo -e "    ${YELLOW}${op}:${NORMAL} all applicable files are on ignore-lists"
    fi
done

# Check for failing linters.
if [ 0 -ne ${#LINTERS_FAILED[@]} ]; then
    for op in "${!LINTERS_FAILED[@]}"; do
        echo -e "$op: ${RED}FAILED${NORMAL}"
    done
    exit 1
fi

# Check for differences.
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
