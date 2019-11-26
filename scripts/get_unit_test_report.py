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
# https://github.com/openbmc/phosphor-dbus-monitor.git               NO
# https://github.com/openbmc/phosphor-sel-logger.git;protocol=git    NO
# ***********************************OUTPUT***********************************
#
# Other outputs and errors are redirected to output.log and debug.log in target_dir.

import argparse
import logging
import os
import shutil
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
    answer = raw_input("Target directory " + working_dir + " already exists. "
                       + "Do you want to delete [Y/N]: ")
    if answer == "Y":
        try:
            shutil.rmtree(working_dir)
            os.mkdir(working_dir)
        except OSError as e:
            print(str(e))
            quit()
    else:
        print("Exiting....")
        quit()

# Create log directory.
log_dir = os.path.join(working_dir, "logs")
try:
    os.mkdir(log_dir)
except OSError as e:
    print("Unable to create log directory: " + log_dir)
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
try:
    output = subprocess.check_output("git clone https://github.com/openbmc/openbmc-build-scripts.git",
                                     shell=True, cwd=working_dir, stderr=subprocess.STDOUT)
    logger.debug(output)
except subprocess.CalledProcessError as e:
    logger.debug(e.output)
    logger.debug(e.cmd)
    logger.debug("Unable to clone openbmc-build-scripts")
    quit()

# Read URLs from input file.
handle = open(args.file)
url_list = handle.readlines()
repo_count = len(url_list)
logger.info("Number of repositories: " + str(repo_count))

# Clone repository and run unit test.
coverage_report = []
counter = 0
total_report_count = 0
coverage_count = 0
unit_test_count = 0
no_report_count = 0
error_count = 0
for url in url_list:
    ci_exists = "NO"
    skip = False
    sandbox_name = url.strip().split('/')[-1].split(";")[0].split(".")[0]
    checkout_cmd = "git clone " + url

    try:
        result = subprocess.check_output(checkout_cmd, shell=True, cwd=working_dir,
                                         stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as e:
        logger.debug(e.output)
        logger.debug(e.cmd)
        logger.debug("Failed to clone " + sandbox_name)
        ci_exists = "ERROR"
        skip = True

    if not(skip):
        docker_cmd = "WORKSPACE=$(pwd) UNIT_TEST_PKG=" + sandbox_name + " " + \
                     "./openbmc-build-scripts/run-unit-test-docker.sh"
        try:
            result = subprocess.check_output(docker_cmd, cwd=working_dir, shell=True,
                                             stderr=subprocess.STDOUT)
            logger.debug(result)
            logger.debug("UT BUILD COMPLETED FOR: " + sandbox_name)

        except subprocess.CalledProcessError as e:
            logger.debug(e.output)
            logger.debug(e.cmd)
            logger.debug("UT BUILD EXITED FOR: " + sandbox_name)
            ci_exists = "ERROR"

        folder_name = os.path.join(working_dir, sandbox_name)
        repo_report_dir = os.path.join(report_dir, sandbox_name)

        report_names = ("coveragereport", "test-suite.log")
        find_cmd = "".join("find " + folder_name + " -name " + report + ";"
                           for report in report_names)
        result = subprocess.check_output(find_cmd, shell=True)
        if result:
            total_report_count += 1
            ci_exists = "YES"
            if result.__contains__("coveragereport"):
                ci_exists += ", COVERAGE"
                coverage_count += 1
            if result.__contains__("test-suite.log"):
                ci_exists += ", UNIT TEST"
                unit_test_count += 1

            result = result.splitlines()
            for file_path in result:
                destination = os.path.dirname(os.path.join(report_dir,
                                                           os.path.relpath(file_path,
                                                                           working_dir)))
                copy_cmd = "mkdir -p " + destination + ";cp -rf " + \
                           file_path.strip() + " " + destination
                subprocess.check_output(copy_cmd, shell=True)
    if ci_exists == "ERROR":
        error_count += 1
    elif ci_exists == "NO":
        no_report_count += 1

    coverage_report.append("{:<65}{:<10}".format(url.strip(), ci_exists))
    counter += 1
    logger.info(str(counter) + " in " + str(repo_count) + " completed")

logger.info("*" * 25 + "UNIT TEST COVERAGE REPORT" + "*" * 25)
for res in coverage_report:
    logger.info(res)
logger.info("*" * 25 + "UNIT TEST COVERAGE REPORT" + "*" * 25)

logger.info("REPORTS: " + report_dir)
logger.info("LOGS: " + log_dir)
logger.info("*" * 75)
logger.info("SUMMARY: ")
logger.info("TOTAL REPOSITORIES     : " + str(repo_count))
logger.info("TESTED REPOSITORIES    : " + str(total_report_count))
logger.info("ERROR                  : " + str(error_count))
logger.info("COVERAGE REPORT        : " + str(coverage_count))
logger.info("UNIT TEST REPORT       : " + str(unit_test_count))
logger.info("NO REPORT              : " + str(no_report_count))
