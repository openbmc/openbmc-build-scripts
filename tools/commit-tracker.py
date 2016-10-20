#!/usr/bin/python

###############################################################################
# @file commit-tracker.py
# @breif Prints out all commits on the master branch of the specified
#        repository, as well as all commits on linked submodule
#        repositories
###############################################################################

import logging
import os
import re
import sys
import time
import git

RED = '\033[31m'
OKBLUE = '\033[94m'
ENDC = '\033[0m'

###############################################################################
# @brief Main function for the script
#
# @param i_args : Command line arguments
###############################################################################
def main(i_args):
    if 3 != len(i_args):
        print usage()

    l_repo_path = i_args[0]
    l_begin_commit = i_args[1]
    l_end_commit = i_args[2]

    print 'Getting commits for ' + l_repo_path
    print_commits(l_repo_path, l_begin_commit, l_end_commit)

###############################################################################
# @brief Prints all the commits from this repo and commits from
#        subrepos between the given references
#
# @param i_repo_path    : The path to the repo to print commits for
# @param i_begin_commit : A references to the most recent commit. What
#                         commit to start printing at
# @param i_end_commit   : A references to the commit farthest in the
#                         past. The commit to stop print at
###############################################################################
def print_commits(i_repo_path, i_begin_commit, i_end_commit, i_level=0):
    try:
        l_repo = git.Repo(i_repo_path)
    except git.exc.InvalidGitRepositoryError:
        logging.error(str(i_repo_path) + ' is not a valid git repository')
        return

    # Get commits between the beginning and end references
    try:
        l_commits = l_repo.iter_commits(rev=(i_begin_commit + '...'
        + i_end_commit))
        # Go through each commit
        for l_commit in l_commits:
            print_commit_info(i_repo_path, l_commit, i_level)
            # Search the diffs for any bumps of submodule versions
            l_diffs = l_commit.diff(str(l_commit.hexsha) + '~1')
            for l_diff in l_diffs:
                # If no files were deleted or added...
                if l_diff.a_path and l_diff.b_path:
                    # ... get info about the change, print it...
                    l_subrepo_uri, l_subrepo_new_hash, l_subrepo_old_hash \
                        = get_bumped_repo(l_repo, str(l_commit.hexsha),                                                  i_repo_path + '/' + l_diff.b_path)
                    logging.debug('Found diff...')
                    logging.debug('  Subrepo URI: ' + str(l_subrepo_uri))
                    logging.debug('  Subrepo new hash: '
                                  + str(l_subrepo_new_hash))
                    logging.debug('  Subrepo old hash: '
                                  + str(l_subrepo_old_hash))
                    logging.debug('  Found in: ' + str(l_diff.a_path))
                    # ... and print the commits for the subrepo if this was a
                    #     version bump
                    if l_subrepo_uri and l_subrepo_uri.startswith('git'):
                        logging.debug('  Bumped')
                        l_subrepo_path = l_subrepo_uri.split('/')[-1]
                        clone_or_update(l_subrepo_uri, l_subrepo_path)
                        print_commits(l_subrepo_path, l_subrepo_new_hash,
                                      l_subrepo_old_hash, i_level=i_level+1)
    except git.exc.GitCommandError:
        logging.error(str(i_begin_commit) + ' and ' + str(i_end_commit)
                      + ' are invalid revisions')

###############################################################################
# @brief Gets the repo uri, the updated hash, and the old hash from a
#        given repo, commit hexsha and file
# 
# @param i_repo      : The Repo object to get bump information from
# @param i_file      : The path to the file to search for bumps
# @param i_hexsha    : The hex hash for the commit to search for bumps
#
# @return Returns the repo URI, the updated hash, and the old hash in
#         a tuple in that order
###############################################################################
def get_bumped_repo(i_repo, i_hexsha, i_file):
    # Checkout the old repo
    i_repo.git.checkout(i_hexsha)
    # Get the diff text
    l_diff_text = i_repo.git.diff(i_hexsha, i_hexsha + '~1', '--', i_file)

    # Get the new and old version hashes
    l_old_hash = None
    l_new_hash = None
    l_old_hash_match = re.search('-SRCREV[+=? ]+"([a-f0-9]+)"', l_diff_text)
    l_new_hash_match = re.search('\+SRCREV[+=? ]+"([a-f0-9]+)"', l_diff_text)
    if l_old_hash_match:
        l_old_hash = l_old_hash_match.group(1)
    if l_new_hash_match:
        l_new_hash = l_new_hash_match.group(1)

    # Get the URI of the subrepo
    l_uri = None
    if os.path.isfile(i_file):
        l_changed_file = open(i_file, 'r')
        for l_line in l_changed_file:
            l_uri_match = re.search('_URI[+=? ]+"([-a-zA-Z0-9/:\.]+)"', l_line)
            if l_uri_match:
                l_uri = l_uri_match.group(1)
                break

    # Go back to master
    i_repo.git.checkout('master')
    return l_uri, l_new_hash, l_old_hash

###############################################################################
# @brief Updates the repo under the given path or clones it from the
#        uri if it doesn't yet exist
#
# @param i_uri  : The URI to the remote repo to clone
# @param i_path : The file path to where the repo currently exists or
#                 where it will be created
###############################################################################
def clone_or_update(i_uri, i_path):
    # If the repo exists, just update it
    if os.path.isdir(i_path):
        l_repo = git.Repo(i_path)
        l_repo.remotes[0].pull()

    # If it doesn't exist, clone it
    else:
        os.mkdir(i_path)
        l_repo = git.Repo.init(i_path)
        origin = l_repo.create_remote('origin', i_uri)
        origin.fetch()
        l_repo.create_head('master', origin.refs.master) \
            .set_tracking_branch(origin.refs.master)
        origin.pull()

###############################################################################
# @brief Prints information for a given commit to the command line
#
# @param i_repo_path    : The file path to the repo
# @param i_commit       : The commit object to print infor for
# @param i_level        : What subrepo level is this
###############################################################################
def print_commit_info(i_repo_path, i_commit, i_level):
    # Define colors for the console
    RED = '\033[31m'
    BLUE = '\033[94m'
    ENDC = '\033[0m'

    # Take just the first seven digits in the commit hash
    l_name_rev = i_commit.name_rev
    l_hash, l_name = l_name_rev.split()
    l_name_rev = l_hash[0:7] + l_name

    # Print out the line describing this commit
    print ('  ' * i_level) + RED + i_repo_path + ENDC  + ' ' + BLUE \
        + l_name_rev + ENDC + ' ' + re.sub('\s+', ' ', i_commit.summary)

###############################################################################
# @brief Prints out the usage for this script
###############################################################################
def usage():
    print 'Usage: commit-tracker.py <repo_name> <begin_rev> <end_rev>'

# Only run main if run as a script
if __name__ == '__main__':
    main(sys.argv[1:])

