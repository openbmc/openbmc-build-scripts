#!/usr/bin/env python

"""
This script determines the given package's openbmc dependencies from its
configure.ac file where it downloads, configures, builds, and installs each of
these dependencies. Then the given package is configured, built, and installed
prior to executing its unit tests.
"""

from git import Repo
from urlparse import urljoin
from subprocess import check_call, call
import os
import sys
import argparse
import collections
import shutil
import re


def check_call_cmd(dir, *cmd):
    """
    Verbose prints the directory location the given command is called from and
    the command, then executes the command using check_call.

    Parameter descriptions:
    dir                 Directory location command is to be called from
    cmd                 List of parameters constructing the complete command
    """
    printline(dir, ">", " ".join(cmd))
    check_call(cmd)


def clone_pkg(pkg):
    """
    Clone the given openbmc package's git repository from gerrit into
    the WORKSPACE location

    Parameter descriptions:
    pkg                 Name of the package to clone
    """
    pkg_repo = urljoin('https://gerrit.openbmc-project.xyz/openbmc/', pkg)
    os.mkdir(os.path.join(WORKSPACE, pkg))
    printline(os.path.join(WORKSPACE, pkg), "> git clone", pkg_repo, "./")
    return Repo.clone_from(pkg_repo, os.path.join(WORKSPACE, pkg))


def add_deps(deps):
    """
    For each <package name>:<regex string> in DEPENDENCIES_REGEX,
    add dependency from package to regex matches if they
    are in dependency list, and set configure flag
    for each match.

    Parameter descriptions:
    deps                Dependency list
    """
    for pkg, value in DEPENDENCIES_REGEX.iteritems():
        for regex_string, config_flag in value.iteritems():
            if pkg in deps:
                pkg_index = deps.index(pkg)
                last_match_index = 0
                for i in range(len(deps)):
                    if re.match(regex_string, deps[i]):
                        set_regex_config_flag(deps[i], config_flag)
                        last_match_index = i
                # Move pkg to index after last match
                if last_match_index > 0:
                    deps.remove(pkg)
                    deps.insert(last_match_index, pkg)

def is_same_flag(config_flag, item):
    if config_flag == item:
        return True
    return ('=' in config_flag) and ('=' in item) and \
       (config_flag.split('=')[0]) == (item.split('=')[0])

def set_regex_config_flag(pkg, config_flag):
    """
    Set regex configure flag for  package CONFIGURE_FLAGS.

    Parameter descriptions:
    pkg                 Dbus Interface
    config_flag         Config flag
    """
    CONFIG_FLAG = config_flag
    if pkg in CONFIGURE_FLAGS:
        has_config_flag = False
        for index, item in enumerate(CONFIGURE_FLAGS[pkg]):
            if is_same_config_flag(config_flag, item):
                CONFIGURE_FLAGS[pkg][index] = CONFIG_FLAG
                has_config_flag = True
                break
        if not has_config_flag:
            CONFIGURE_FLAGS[pkg].append(CONFIG_FLAG)
    else:
        CONFIGURE_FLAGS[pkg] = [CONFIG_FLAG]


def get_deps(configure_ac):
    """
    Parse the given 'configure.ac' file for package dependencies and return
    a list of the dependencies found.

    Parameter descriptions:
    configure_ac        Opened 'configure.ac' file object
    """
    line = ""
    dep_pkgs = set()
    for cfg_line in configure_ac:
        # Remove whitespace & newline
        cfg_line = cfg_line.rstrip()
        # Check for line breaks
        if cfg_line.endswith('\\'):
            line += str(cfg_line[:-1])
            continue
        line = line+cfg_line

        # Find any defined dependency
        line_has = lambda x: x if x in line else None
        macros = set(filter(line_has, DEPENDENCIES.iterkeys()))
        if len(macros) == 1:
            macro = ''.join(macros)
            deps = filter(line_has, DEPENDENCIES[macro].iterkeys())
            dep_pkgs.update(map(lambda x: DEPENDENCIES[macro][x], deps))

        line = ""
    deps = list(dep_pkgs)

    return deps


def build_depends(pkg, pkgdir, dep_installed):
    """
    For each package(pkg), starting with the package to be unit tested,
    parse its 'configure.ac' file from within the package's directory(pkgdir)
    for each package dependency defined recursively doing the same thing
    on each package found as a dependency.

    Parameter descriptions:
    pkg                 Name of the package
    pkgdir              Directory where package source is located
    dep_installed       Current list of dependencies and installation status
    """
    os.chdir(pkgdir)
    # Open package's configure.ac
    with open("configure.ac", "rt") as configure_ac:
        # Retrieve dependency list from package's configure.ac
        configure_ac_deps = get_deps(configure_ac)
        for dep_pkg in configure_ac_deps:
            # Dependency package not already known
            if dep_installed.get(dep_pkg) is None:
                # Dependency package not installed
                dep_installed[dep_pkg] = False
                dep_repo = clone_pkg(dep_pkg)
                # Determine this dependency package's
                # dependencies and install them before
                # returning to install this package
                dep_pkgdir = os.path.join(WORKSPACE, dep_pkg)
                dep_installed = build_depends(dep_pkg,
                                              dep_repo.working_dir,
                                              dep_installed)
            else:
                # Dependency package known and installed
                if dep_installed[dep_pkg]:
                    continue
                else:
                    # Cyclic dependency failure
                    raise Exception("Cyclic dependencies found in "+pkg)

    # Build & install this package
    if not dep_installed[pkg]:
        conf_flags = []
        os.chdir(pkgdir)
        # Add any necessary configure flags for package
        if CONFIGURE_FLAGS.get(pkg) is not None:
            conf_flags.extend(CONFIGURE_FLAGS.get(pkg))
        check_call_cmd(pkgdir, './bootstrap.sh')
        check_call_cmd(pkgdir, './configure', *conf_flags)
        check_call_cmd(pkgdir, 'make')
        check_call_cmd(pkgdir, 'make', 'install')
        dep_installed[pkg] = True

    return dep_installed


def create_dep_list(pkg, pkgdir, dep_checked, repo_dirs):
    """
    For each package(pkg), starting with the package to be unit tested,
    parse its 'configure.ac' file from within the package's directory(pkgdir)
    for each package dependency defined recursively doing the same thing
    on each package found as a dependency. This creates an ordered list of
    dependencies without installing packages.

    Parameter descriptions:
    pkg                 Name of the package
    pkgdir              Directory where package source is located
    dep_checked       Current list of dependencies and installation status
    repo_dirs         Current list of cloned repo directories
    """
    os.chdir(pkgdir)
    # Open package's configure.ac
    with open("configure.ac", "rt") as configure_ac:
        # Retrieve dependency list from package's configure.ac
        configure_ac_deps = get_deps(configure_ac)
        for dep_pkg in configure_ac_deps:
            # Dependency package not already known
            if dep_checked.get(dep_pkg) is None:
                # Dependency package not checked
                dep_checked[dep_pkg] = False
                dep_repo = clone_pkg(dep_pkg)
                # Determine this dependency package's
                # dependencies and check them
                dep_pkgdir = os.path.join(WORKSPACE, dep_pkg)
                dep_checked, repo_dirs = create_dep_list(dep_pkg,
                                                      dep_repo.working_dir,
                                                      dep_checked,
                                                      repo_dirs)
                repo_dirs.append(dep_repo.working_dir)
            else:
                # Dependency package known and installed
                if dep_checked[dep_pkg]:
                    continue
                else:
                    # Cyclic dependency failure
                    raise Exception("Cyclic dependencies found in "+pkg)
    if not dep_checked[pkg]:
        dep_checked[pkg] = True
    return dep_checked, repo_dirs



if __name__ == '__main__':
    # CONFIGURE_FLAGS = [GIT REPO]:[CONFIGURE FLAGS]
    CONFIGURE_FLAGS = {
        'phosphor-objmgr': ['--enable-unpatched-systemd'],
        'sdbusplus': ['--enable-transaction'],
        'phosphor-logging':
        ['--enable-metadata-processing',
         'YAML_DIR=/usr/local/share/phosphor-dbus-interfaces/yaml']
    }

    # DEPENDENCIES = [MACRO]:[library/header]:[GIT REPO]
    DEPENDENCIES = {
        'AC_CHECK_LIB': {'mapper': 'phosphor-objmgr'},
        'AC_CHECK_HEADER': {
            'host-ipmid': 'phosphor-host-ipmid',
            'sdbusplus': 'sdbusplus',
            'phosphor-logging/log.hpp': 'phosphor-logging',
        },
        'AC_PATH_PROG': {'sdbus++': 'sdbusplus'},
        'PKG_CHECK_MODULES': {
            'phosphor-dbus-interfaces': 'phosphor-dbus-interfaces',
            'openpower-dbus-interfaces': 'openpower-dbus-interfaces',
            'sdbusplus': 'sdbusplus',
            'phosphor-logging': 'phosphor-logging',
        },
    }

    # DEPENDENCIES_REGEX = [GIT REPO]:[REGEX STRING]:[CONFIG_FLAG]
    DEPENDENCIES_REGEX = {
        'phosphor-logging': {
             '\S+-dbus-interfaces$':
                 'YAML_DIR=/usr/local/share/phosphor-dbus-interfaces/yaml'
             },
    }

    # Set command line arguments
    parser = argparse.ArgumentParser()
    parser.add_argument("-w", "--workspace", dest="WORKSPACE", required=True,
                        help="Workspace directory location(i.e. /home)")
    parser.add_argument("-p", "--package", dest="PACKAGE", required=True,
                        help="OpenBMC package to be unit tested")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="Print additional package status messages")
    args = parser.parse_args(sys.argv[1:])
    WORKSPACE = args.WORKSPACE
    UNIT_TEST_PKG = args.PACKAGE
    if args.verbose:
        def printline(*line):
            for arg in line:
                print arg,
            print
    else:
        printline = lambda *l: None

    prev_umask = os.umask(000)
    # Determine dependencies and install them
    dep_installed = dict()
    dep_installed[UNIT_TEST_PKG] = False

    dep_checked = collections.OrderedDict()
    repo_dirs = list()
    dep_checked[UNIT_TEST_PKG] = False
    dep_list, repo_dirs = create_dep_list(UNIT_TEST_PKG,
                                        os.path.join(WORKSPACE, UNIT_TEST_PKG),
                                        dep_checked,
                                        repo_dirs)
    for repo_dir in repo_dirs:
        shutil.rmtree(repo_dir)
    ordered_list = dep_list.keys()
    ordered_list.reverse()
    add_deps(ordered_list)
    dep_installed = build_depends(UNIT_TEST_PKG,
                                  os.path.join(WORKSPACE, UNIT_TEST_PKG),
                                  dep_installed)
    os.chdir(os.path.join(WORKSPACE, UNIT_TEST_PKG))
    # Refresh dynamic linker run time bindings for dependencies
    check_call_cmd(os.path.join(WORKSPACE, UNIT_TEST_PKG), 'ldconfig')
    # Run package unit tests
    if args.verbose:
        check_call_cmd(os.path.join(WORKSPACE, UNIT_TEST_PKG), 'make', 'check',
                       'VERBOSE=1')
    else:
        check_call_cmd(os.path.join(WORKSPACE, UNIT_TEST_PKG), 'make', 'check')
    os.umask(prev_umask)

