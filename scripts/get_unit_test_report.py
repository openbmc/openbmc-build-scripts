#!/usr/bin/python

# This script generates the unit test coverage report.
#
# Usage:
# get_unit_test_report.py file target_dir
#
# Description of arguments:
# file        File with repository URLs, one on each line without quotes.
#             Eg: git://github.com/openbmc/ibm-dbus-interfaces
# target_dir  Target directory in pwd to place all cloned repos and logs.
#
# Eg: get_unit_test_report.py repo_names target_dir
#
# Output format:
#
# ***********************************OUTPUT***********************************
# git://github.com/openbmc/phosphor-dbus-monitor                   NO
# git://github.com/openbmc/phosphor-sel-logger.git;protocol=git    NO
# ***********************************OUTPUT***********************************
#
# Other outputs and errors are redirected to output.log and debug.log in target_dir.

import argparse
import logging
import os
import sys
import subprocess


# Create parser.
parser = argparse.ArgumentParser(usage='%(prog)s file target_dir',
                                 description="Script generates the unit test coverage report")

parser.add_argument("file", type=str,
                    help='''Text file containing repository links separated by
                            new line
                            Eg: git://github.com/openbmc/ibm-dbus-interfaces''')

parser.add_argument("target_dir", type=str,
                    help='''Name of a non-existing directory in pwd to store all
                            cloned repos, logs and UT reports''')
args = parser.parse_args()


# Create target working directory.
pwd = os.getcwd()
working_dir = os.path.join(pwd, args.target_dir)
try:
    os.mkdir(working_dir)
except OSError as e:
    print("Target directory " + working_dir + " already exists. Please give a "
          + "new name.")
    print(str(e))
    quit()

# Create log directory.
log_dir = os.path.join(working_dir, "logs")
try:
    os.mkdir(log_dir)
except OSError as e:
    print("Unable to create log directory: " + report_dir)
    print(str(e))
    quit()


# Log files
debug_file = os.path.join(log_dir, "debug.log")
output_file = os.path.join(log_dir, "output.log")
logging.basicConfig(format='%(levelname)s - %(message)s', level=logging.DEBUG,
                    filename=debug_file)
logger = logging.getLogger(__name__)

# Create handlers
console_handler = logging.StreamHandler()
file_handler = logging.FileHandler(output_file)
console_handler.setLevel(logging.INFO)
file_handler.setLevel(logging.INFO)

# Create formatters and add it to handlers
log_format = logging.Formatter('%(message)s')
console_handler.setFormatter(log_format)
file_handler.setFormatter(log_format)

# Add handlers to the logger
logger.addHandler(console_handler)
logger.addHandler(file_handler)


# Create report directory.
report_dir = os.path.join(working_dir, "reports")
try:
    os.mkdir(report_dir)
except OSError as e:
    logger.error("Unable to create report directory: " + report_dir)
    logger.error(str(e))
    quit()


# Clone OpenBmc build scripts.
proc = subprocess.Popen("git clone https://github.com/openbmc/openbmc-build-scripts.git",
                        shell=True, cwd=working_dir, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE)
stdout, stderr = proc.communicate()
proc.wait()

# Read URLs from input file.
handle = open(args.file)
url_list = handle.readlines()
repo_count = len(url_list)
logger.info("Number of repositories: " + str(repo_count))

coverage_report = []
counter = 0

for url in url_list:
    sandbox_name = url.strip().split('/')[-1].split(";")[0].split(".")[0]

    checkout_cmd = "git clone " + url
    subprocess.Popen(checkout_cmd, shell=True, cwd=working_dir,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    docker_cmd = "WORKSPACE=$(pwd) UNIT_TEST_PKG=" + sandbox_name + " " + \
                 "./openbmc-build-scripts/run-unit-test-docker.sh"
    proc = subprocess.Popen(docker_cmd, shell=True, cwd=working_dir,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    stdout, stderr = proc.communicate()
    proc.wait()

    logger.debug(stdout)
    logger.debug(stderr)

    ci_exists = "NO"
    folder_name = os.path.join(working_dir, sandbox_name)
    repo_report_dir = os.path.join(report_dir, sandbox_name)

    report_names = ("coveragereport", "test-suite.log")
    for report in report_names:
        find_cmd = "find " + folder_name + " -name " + report
        result = subprocess.check_output(find_cmd, shell=True)
        if result:
            ci_exists = "YES"
            result = result.splitlines()[0]
            copy_cmd = "mkdir -p " + repo_report_dir + ";cp -rf " + \
                       result.strip() + " " + repo_report_dir
            subprocess.check_output(copy_cmd, shell=True)

    coverage_report.append("{:<65}{:<10}".format(url.strip(), ci_exists))
    counter += 1
    logger.info(str(counter) + " in " + str(repo_count) + " completed")

logger.info("*" * 25 + "UNIT TEST COVERAGE REPORT" + "*" * 25)
for res in coverage_report:
    logger.info(res)
logger.info("*" * 25 + "UNIT TEST COVERAGE REPORT" + "*" * 25)

logger.info("REPORTS: " + report_dir)
logger.info("LOGS: " + log_dir)
