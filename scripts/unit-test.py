#!/usr/bin/env python

"""
This script determines the given package's openbmc dependencies from its
configure.ac file where it downloads, configures, builds, and installs each of
these dependencies. Then the given package is configured, built, and installed
prior to executing its unit tests.
"""

from git import Repo
from urlparse import urljoin
from subprocess import check_call, call, check_output
import os
import sys
import argparse
import re

def launch_session_dbus(dbus_dir, dbus_config_file):
    """
    Launches a session debus using a modified config file and
    sets the DBUS_SESSION_BUS_ADDRESS environment variable

    Parameter descriptions:
    dbus_dir            Directory location for generated files
    dbus_config_file    File location of dbus sys config file
    """
    dbus_pid = os.path.join(dbus_dir,'pid')
    dbus_socket = os.path.join(dbus_dir,'system_bus_socket')
    dbus_local_conf = os.path.join(dbus_dir,'system-local.conf')
    if os.path.isfile(dbus_pid):
        os.remove(dbus_pid)
    with open(dbus_config_file) as infile, \
         open(dbus_local_conf, 'w') as outfile:
        for line in infile:
            line = re.sub('<type>.*</type>','<type>session</type>', \
                          line, flags=re.DOTALL)
            line = re.sub('<pidfile>.*</pidfile>', \
                          '<pidfile>%s</pidfile>' % dbus_pid, \
                          line, flags=re.DOTALL)
            line = re.sub('<listen>.*</listen>', \
                          '<listen>unix:path=%s</listen>' % dbus_socket, \
                          line, flags=re.DOTALL)
            line = re.sub('<deny','<allow', line)
            outfile.write(line)
    infile.close()
    outfile.close()
    command = ['dbus-launch', '--config-file=%s' % dbus_local_conf]
    out = check_output(command).splitlines()
    for line in out:
        p = re.compile('DBUS_SESSION_BUS_ADDRESS=(.*)')
        matches = p.search(line)
        BUS_ADDR = matches.group(1)
        os.environ['DBUS_SESSION_BUS_ADDRESS'] = BUS_ADDR
        break


def dbus_cleanup(dbus_dir):
    """
    Kills the dbus session started by launch_session_dbus
    and removes the generated files.

    Parameter descriptions:
    dbus_dir            Directory location of generated files
    """

    dbus_pid = os.path.join(dbus_dir,'pid')
    dbus_socket = os.path.join(dbus_dir,'system_bus_socket')
    dbus_local_conf = os.path.join(dbus_dir,'system-local.conf')
    if os.path.isfile(dbus_pid):
        dbus_pid = open(dbus_pid,'r').read().replace('\n','')
        check_call_cmd(dbus_dir, 'kill', dbus_pid)
    if os.path.isfile(dbus_local_conf):
        os.remove(dbus_local_conf)
    if os.path.exists(dbus_socket):
        os.remove(dbus_socket)


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

    return list(dep_pkgs)


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
        conf_flags = ""
        os.chdir(pkgdir)
        # Add any necessary configure flags for package
        if CONFIGURE_FLAGS.get(pkg) is not None:
            conf_flags = " ".join(CONFIGURE_FLAGS.get(pkg))
        check_call_cmd(pkgdir, './bootstrap.sh')
        check_call_cmd(pkgdir, './configure', conf_flags)
        check_call_cmd(pkgdir, 'make')
        check_call_cmd(pkgdir, 'make', 'install')
        dep_installed[pkg] = True

    return dep_installed


if __name__ == '__main__':
    # CONFIGURE_FLAGS = [GIT REPO]:[CONFIGURE FLAGS]
    CONFIGURE_FLAGS = {
        'phosphor-objmgr': ['--enable-unpatched-systemd'],
        'sdbusplus': ['--enable-transaction']
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
            'sdbusplus': 'sdbusplus',
            'phosphor-logging': 'phosphor-logging',
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
    parser.add_argument("-t", "--tempdbusdir", dest="DBUS_DIR", required=True,
                        help="Temp dbus dir, must be unique")
    parser.add_argument("-c", "--dbussysconfigfile",
                        dest="DBUS_SYS_CONFIG_FILE",
                        required=True, help="Dbus sys config file location")
    args = parser.parse_args(sys.argv[1:])
    WORKSPACE = args.WORKSPACE
    UNIT_TEST_PKG = args.PACKAGE
    DBUS_DIR = args.DBUS_DIR
    DBUS_SYS_CONFIG_FILE = args.DBUS_SYS_CONFIG_FILE
    if args.verbose:
        def printline(*line):
            for arg in line:
                print arg,
            print
    else:
        printline = lambda *l: None

    prev_umask = os.umask(000)
    launch_session_dbus(DBUS_DIR, DBUS_SYS_CONFIG_FILE)
    # Determine dependencies and install them
    dep_installed = dict()
    dep_installed[UNIT_TEST_PKG] = False
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
    dbus_cleanup(DBUS_DIR)
