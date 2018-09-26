#!/usr/bin/env python

import argparse
import re
import os
import urllib
import xml.etree.ElementTree as ET


parser = argparse.ArgumentParser(
    usage='%(prog)s [OPTIONS] [FILE...]',
    description="""
        %(prog)s parses a failed status file for regexes contained in the
        specified regex file(s). When the first match is found it will print
        the name of the regex file the matching regex was contained in as the
        failure type. It will also print the regex and matching string if one
        is found. If no match is found, it will instead just print failure
        type as \"unknown\".
        """,
    formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    prefix_chars='-+')
parser.add_argument(
    '--url',
    default="",
    help="""
        URL to retrieve status file from. Content retrieved from the URL will
        be saved to the --status_file_path.
        """)
parser.add_argument(
    '--status_file_path',
    default="jenkins_log",
    help="""
        Path of the status file.  If using the "--url" option, the status file
        will be overwritten.
        """)
parser.add_argument(
    '--prop_file_path',
    default=None,
    help="""
        Optional. If this is set, failure analysis results will be written
        to the file in a form readable as Jenkins environment variables.
    """)
parser.add_argument(
    'regex_file_paths',
    default=["developer", "infrastructure"],
    nargs='*',
    help="""
        A space-separated list of XML files containing issues and regexes
        to be used in failure analysis. An issue is an XML element with a
        name attribute, with zero or more regex child elements,
        and zero or more child issue elements. An issue represents a
        cause for a Jenkins job failure detected when one of the issue's regex
        children is found in the log file. Files are processed in the order
        listed. If any regex from a file matches status file data, the
        issue name will double as the failure type (e.g. "infrastructure",
        "developer"). If a sub-issue type matches, the issue names with
        colon ":" delimiter will be used as the failure type
        (e.g. "infrastructure:command not found").
        NOTE: %(prog)s's directory path will be set as the current
        working directory for the purposes of finding unqualified files.
        """)
args = parser.parse_args()


def process_issue(node, file_data):

    r"""
    Return a tuple consisting of 1) the list of issue names leading to the
    first regex in the node that matches the file data 2) the matched text
    and 3) the regex.

    If no match is found, return a tuple of (None, None, None).

    Given the following file data:
    "failed to connect to simics server"

    Given the following node data:
    <issues>
        <issue name="infrastructure">
            <issue name="command not found">
                <regex>.*sh:.*: command not found</regex>
            </issue>
            <issue name="connection">
                <regex>.*failed to connect to simics server</regex>
            </issue>
            <regex>\*\*ERROR\*\* Ending.*autoipl\.C with exit code of 1</regex>
            <regex>.*Issuing: vexec.*\nRunning on.*\n.*=*\n.*\*\*ERROR\*\*.*</regex>
            <regex>ERROR: failed to.*simics.*rc=1</regex>
            <regex>ERROR: test timeout failure</regex>
            <regex>.*Exit code from private simics.*is 1</regex>
            <regex>.*open_fsp_session failure.*telnet.*retries</regex>
            <regex>.*cannot stat.*No such file or directory</regex>
            <regex>.*write error: No space left on device</regex>
        </issue>
    </issues>

    When the first regex matches, this function would return the tuple
    (["issues", "connection"], "failed to connect to simics server",
    "(.*failed to connect to simics server)).

    Description of argument(s):
    node       A node comprised of data such as that returned by
               xml.etree.ElementTree.parse of an XML file such as
               the "developer" or "infrastructure" XML files.
    file_data  A string containing the output of a test run.
    """

    for element in node:
        if element.tag == 'regex':
            regex = "(" + element.text + ")"
            matches = re.search(regex, file_data)
            if matches:
                return [], matches.group(1), regex
        elif element.tag == 'issue':
            matched_names, matched_text, matched_regex = process_issue(element,
                                                                       file_data)
            if matched_names != None:
                matched_names.insert(0, element.get('name'))
                return matched_names, matched_text, matched_regex
    return None, None, None


def validate_parms():
    r"""
    Validate program parameters, etc.  Return True or False (i.e. pass/fail)
    accordingly.
    """

    os.chdir(os.path.dirname(os.path.realpath(__file__)))

    # Check file paths are valid.
    regex_file_paths = list(args.regex_file_paths)
    for regex_file_path in regex_file_paths:
        if not os.path.isfile(regex_file_path):
            return False

    # Check if URL is valid and readable.
    if args.url == "":
        if not os.path.isfile(args.status_file_path):
            return False
    else:
        try:
            urllib.urlopen(args.url).read()
        except IOError as e:
            print e
            return False

    return True


def main():

    if not validate_parms():
        return False

    # Retrieve the url, and save to the logpath specified.
    if not args.url == "":
        urllib.urlretrieve(args.url, args.status_file_path)

    # Read the log into a variable.
    with open(args.status_file_path, 'r') as status_file:
        status_file_stream = status_file.read()

    # Import the regex list.
    for regex_file_path in list(args.regex_file_paths):
        # Get regexes root.
        root = ET.parse(regex_file_path).getroot()
        failure_list, match_text, regex = process_issue(root,
                                                        status_file_stream)
        if failure_list:
            failure_type = ":".join(failure_list)
            # Print match results.
            print "failure_type: " + str(failure_type)
            print "regex: " + str(regex)
            print "match_text:\n", match_text
            # If the user set prop_file_path, write results to the file.
            if args.prop_file_path:
                print "Writing to properties file at" \
                      + str(args.prop_file_path)
                with open(args.prop_file_path, "w+") as prop_file:
                    prop_file.write('FAIL_ANALYSIS_FAILURE_TYPE='
                                    + failure_type + '\n')
                    prop_file.write('FAIL_ANALYSIS_REGEX='
                                    + regex + '\n')
            return True

    # If we were not able to identify the failure, set the failure
    # type to unknown.
    failure_type = "unknown"
    print "failure_type: " + str(failure_list)

    # If the user set prop_file_path, write results to the file.
    if args.prop_file_path:
        print "Writing to properties file at " + args.prop_file_path + "."
        with open(args.prop_file_path, "w+") as prop_file:
            prop_file.write('FAIL_ANALYSIS_FAILURE_TYPE='
                            + failure_type + '\n')
    return True


if not main():
    exit(1)
