"""Generate the code coverage metrics for oBMC-Git REpos.

The functions in this file generates the code coverage metrics from lcov/gcov
reports of HTML format, with different build configs. These metrics are 
currently printed out together.

Positional Arguments:
    target_dir - Path to directory of generated lcov/gcov data.
"""

import datetime
import os
import glob
import re
import argparse
from typing import List, Tuple

# The following path depends on the Meson build configuration.
_MESON_CODE_COVERAGE_REPORT_PATH = (
    '{repo_name}/build/meson-logs/coveragereport/index.html')
_MESON_START_LINE = 93
_MESON_LINE_DIFF = 12
_MESON_END_LINE_DIFF = 16

# The following path depends on the GNU autotool build configuration.
_AUTOTOOL_CODE_COVERAGE_REPORT_PATH = ('{repo_name}/{repo_name}-*/index.html')
_AUTOTOOL_START_LINE = 86
_AUTOTOOL_LINE_DIFF = 10
_AUTOTOOL_END_LINE_DIFF = 15

# The following path depends on the CMake build configuration.
_CMAKE_CODE_COVERAGE_REPORT_PATH = (
    '{repo_name}/check-code-coverage/index.html')
_CMAKE_START_LINE = 77
_CMAKE_LINE_DIFF = 10
_CMAKE_END_LINE_DIFF = 14

# Build configurations.
_BUILD_CONF = {'meson': [_MESON_CODE_COVERAGE_REPORT_PATH,
                         [_MESON_START_LINE,
                          _MESON_LINE_DIFF,
                          _MESON_END_LINE_DIFF]],
               'autotool': [_AUTOTOOL_CODE_COVERAGE_REPORT_PATH,
                            [_AUTOTOOL_START_LINE,
                             _AUTOTOOL_LINE_DIFF,
                             _AUTOTOOL_END_LINE_DIFF]],
               'cmake': [_CMAKE_CODE_COVERAGE_REPORT_PATH,
                         [_CMAKE_START_LINE,
                          _CMAKE_LINE_DIFF,
                          _CMAKE_END_LINE_DIFF]]}


# Directories with the following keywords are excluded to compute code coverage.
_DIRECTORY_KEYWORDS_TO_BE_EXCLUDED = ['test', 'xyz/openbmc_project']

# The following patterns are required to find the directory name.
_DIRECTORY_NAME_PRE_PATTERN = 'index.html\">'
_DIRECTORY_NAME_POST_PATTERN = '</a></td>'

# Output messages templates.
_OUTPUT_TEXT_ERROR = '''*********************************
{repo_name}
Error: Could not generate data for {repo_name}
*********************************
'''

_OUTPUT_TEXT = '''*********************************
{repo_name}
Covered Lines: {covered_lines}
Total Lines: {total_lines}
Covered Functions: {covered_functions}
Total Functions: {total_functions}
Lines to Coverage Ratio: {lines_coverage_ratio}
Functions to Coverage Ratio: {functions_coverage_ratio}
LCov: {lcov_path}
*********************************
'''


text = '''%(prog)s target_dir

Example usages:
get_unit_test_report.py target_dir'''

parser = argparse.ArgumentParser(usage=text,
                                 description="Script aggregates resulst from unit tests together")
parser.add_argument("target_dir", type=str,
                    help='''Path of the existing directory of lcov data created from 
                            running unit tests. Meant to work with ./get_unit_test_report.py''')
args = parser.parse_args()

coverage_data = {}


def _find_build_conf(repo_name: str) -> Tuple[str, List[int]]:
    """Find the build conf based on the report path.

    Args:
        repo_name: repo name.

    Returns:
        A tuple that contains a string of the formatted report path and a list of
        the repo's line statistics based on its build type.
    """

    # There are more repos built with meson and autotool,
    # so we first evaluate them.
    for build_type in _BUILD_CONF:
        # Complete the path based on the build type.
        report_path = os.path.join(
            args.target_dir,
            _BUILD_CONF[build_type][0].format(repo_name=repo_name))
        print(report_path)
        #  Evaluate the path.
        if build_type == 'autotool':
            # Autotool does not have a specific code coverage report path.
            possible_paths = glob.glob(report_path)
            if possible_paths:
                return str(possible_paths[0]), _BUILD_CONF[build_type][1]
        elif os.path.exists(report_path):
            return report_path, _BUILD_CONF[build_type][1]

    return None, None


def get_individual_code_coverage_metric(repo_name: str) -> None:
    """Crawl a report and aggregate the results together

    Args:
        repo_name: the name of the repo.

    Raises:
        ValueError: the code coverage report has a different html format.
    """
    report_path, line_stat = _find_build_conf(repo_name)
    if report_path is None and line_stat is None:
        coverage_data[repo_name] = None
        return

    with open(report_path, "r") as f:
        report_content = f.readlines()

    # We get all the data directly from the html file.
    covered_lines = 0
    total_lines = 0
    covered_functions = 0
    total_functions = 0
    for index in range(line_stat[0],
                       len(report_content) - line_stat[2],
                       line_stat[1]):
        line_with_directory_name = index - 5
        tmp_directory = report_content[line_with_directory_name].partition(
            _DIRECTORY_NAME_PRE_PATTERN)[2].partition(
                _DIRECTORY_NAME_POST_PATTERN)[0]
        if any(k in tmp_directory for k in _DIRECTORY_KEYWORDS_TO_BE_EXCLUDED):
            continue
        tmp_lines = re.findall(r'\d+', report_content[index])
        tmp_functions = re.findall(r'\d+', report_content[index+2])
        if len(tmp_lines) != 2 or len(tmp_functions) != 2:
            raise ValueError(
                f'The code coverage report {report_path} has a different html '
                f'format and line {index} is not the line with '
                'the code coverage data')
        covered_lines += int(tmp_lines[0])
        total_lines += int(tmp_lines[1])
        covered_functions += int(tmp_functions[0])
        total_functions += int(tmp_functions[1])
        lines_coverage_ratio = round(100*covered_lines/total_lines, 2)
        functions_coverage_ratio = round(
            100*covered_functions/total_functions, 2)

        coverage_data[repo_name] = {"covered_lines": str(covered_lines),
                                    "total_lines": str(total_lines),
                                    "covered_functions": str(covered_functions),
                                    "total_functions": str(total_functions),
                                    "lines_coverage_ratio": str(lines_coverage_ratio),
                                    "functions_coverage_ratio": str(functions_coverage_ratio),
                                    "lcov_path": report_path}


for folder in os.listdir(args.target_dir):
    path = os.path.join(args.target_dir, folder, "build", "meson-logs")
    if os.path.exists(path):
        get_individual_code_coverage_metric(folder)

# Print out resulting data
with open(os.path.join(args.target_dir, "reports", "raw_output"), "w") as f:
    f.write("Code Coverage Report: " + str(datetime.date.today()))
    for repo_name, repo_cov in coverage_data.items():
        if repo_cov is None:
            output = _OUTPUT_TEXT_ERROR.format(repo_name=repo_name)
            f.write(output)
        else:
            output = _OUTPUT_TEXT.format(repo_name=repo_name,
                                         covered_lines=repo_cov["covered_lines"],
                                         total_lines=repo_cov["total_lines"],
                                         covered_functions=repo_cov["covered_functions"],
                                         total_functions=repo_cov["total_functions"],
                                         lines_coverage_ratio=repo_cov["lines_coverage_ratio"],
                                         functions_coverage_ratio=repo_cov["functions_coverage_ratio"],
                                         lcov_path=repo_cov["lcov_path"])
            f.write(output)

for repo_name, repo_cov in coverage_data.items():
    if repo_cov is None:
        output = _OUTPUT_TEXT_ERROR.format(repo_name=repo_name)
        print(output)
    else:
        output = _OUTPUT_TEXT.format(repo_name=repo_name,
                                     covered_lines=repo_cov["covered_lines"],
                                     total_lines=repo_cov["total_lines"],
                                     covered_functions=repo_cov["covered_functions"],
                                     total_functions=repo_cov["total_functions"],
                                     lines_coverage_ratio=repo_cov["lines_coverage_ratio"],
                                     functions_coverage_ratio=repo_cov["functions_coverage_ratio"],
                                     lcov_path=repo_cov["lcov_path"])
        print(output)
