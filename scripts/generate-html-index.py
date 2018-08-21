#!/usr/bin/env python

r"""
Creates a index files that can be displayed as web pages in a given directory
and all its subdirectories. There are options to exclude certain files and
subdirectories.
"""

import argparse
import os
import sys


def main(i_raw_args):
    l_args = parse_args(i_raw_args)
    create_index_file(l_args.logs_dir, '/', l_args.exclude)


def create_index_file(i_dir_path, i_pretty_path, i_exclude_list):
    r"""
    Create HTML index files for a given directory and all its subdirectories.

    Description of argument(s):
    i_dir_path      The directory to generate an index file for.
    i_pretty_path   A pretty version of i_dir_path that can be shown to
                    readers of the HTML page.
    i_exclude_list  A list of files and directories to exclude from
    """

    l_index_file_path = os.path.join(i_dir_path, 'index.html')
    l_list_dir = os.listdir(i_dir_path)

    # Created a sorted list of subdirectories in this directory
    l_dirs = sorted(
        [d for d
         in l_list_dir
         if os.path.isdir(os.path.join(i_dir_path, d))
            and d not in i_exclude_list])

    # Create a sorted list of files in this directory
    l_files = sorted(
        [f for f
         in l_list_dir
         if not os.path.isdir(os.path.join(i_dir_path, f))
            and f not in i_exclude_list])

    # Open up the index file we're going to write to.
    with open(l_index_file_path, 'w+') as l_index_file:
        l_index_file.write(
            '<html>\n'
            '<head><title>' + i_pretty_path + '</title></head>\n'
            '<body>\n'
            '<h2>OpenBMC Logs</h2>\n'
            '<h3>' + i_pretty_path + '</h3>\n')

        # Only show the link to go up a directory if this is not the root.
        if not i_pretty_path == '/':
            l_index_file.write('<a href=".."><img src="/dir.png"> ..</a><br>\n')

        # List directories first.
        for l_dir in l_dirs:
            l_index_file.write(
                '<a href="%s"><img src="/dir.png"> %s</a><br>\n'
                % (l_dir, l_dir))
            create_index_file(
                os.path.join(i_dir_path, l_dir),
                i_pretty_path + l_dir + '/',
                i_exclude_list)

        # List files second.
        for l_file in l_files:
            l_index_file.write('<a href="%s"><img src="/file.png"> %s</a><br>\n'
                               % (l_file, l_file))

        l_index_file.write('</body>\n</html>')


def parse_args(i_raw_args):
    r"""
    Parse the given list as command line arguments and return an object with
    the argument values.

    Description of argument(s):
    i_raw_args  A list of command line arguments, usually taken from
                sys.argv[1:].
    """

    parser = argparse.ArgumentParser()
    parser.add_argument(
        'logs_dir',
        help='Directory containing the logs that should be uploaded.')
    parser.add_argument(
        '--exclude',
        nargs='+',
        default=['.git', 'index.html'],
        help='A list of files to exclude from the index.'
    )
    return parser.parse_args(i_raw_args)


if __name__ == '__main__':
    main(sys.argv[1:])