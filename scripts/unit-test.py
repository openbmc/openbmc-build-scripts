#!/usr/bin/env python
#
# Execute the given repository's unit tests
#

from subprocess import call
import os
import sys
import subprocess

# CONFIGURE_FLAGS = [GIT REPO]:[CONFIGURE FLAGS]
CONFIGURE_FLAGS = {
    'phosphor-objmgr': '--enable-unpatched-systemd'
}

# DEPENDENCIES = [MACRO]:[library/header]:[GIT REPO]
DEPENDENCIES = {
    'AC_CHECK_LIB': {'mapper': 'phosphor-objmgr'},
    'AC_CHECK_HEADER': {'host-ipmid/ipmid-api.h': 'phosphor-host-ipmid'}
}

# Get workspace directory (package source to be tested)
WORKSPACE = os.environ.get('WORKSPACE')
if WORKSPACE is None:
    raise Exception("Environment variable 'WORKSPACE' not set")

# Determine package name
UNIT_TEST_PKG = os.environ.get('UNIT_TEST_PKG')
if UNIT_TEST_PKG is None:
    raise Exception("Environment variable 'UNIT_TEST_PKG' not set")

# Retrieve user to update all workspace files ownership to
EXIT_USER = os.environ.get('EXIT_USER')
if EXIT_USER is None:
    print "WARNING: 'EXIT_USER' variable not set, attempting to use ${USER}"
    EXIT_USER = os.environ.get('USER')


def clone_pkg(pkg):
    pkg_repo = "https://gerrit.openbmc-project.xyz/openbmc/"+pkg
    os.chdir(WORKSPACE)
    print WORKSPACE+"> git clone "+pkg_repo
    subprocess.check_call(['git', 'clone', pkg_repo])


# For each package(pkg), starting with the package to be unit tested,
# parse its 'configure.ac' file from within the package's directory(pkgdir)
# for each package dependency defined recursively doing the same thing
# on each package found as a dependency.
def build_depends(pkg=None, pkgdir=None, deps=None):
    os.chdir(pkgdir)
    try:
        # Open package's configure.ac
        with open("configure.ac", "rt") as infile:
            line = ""
            for cfg_line in infile:
                cfg_line = cfg_line.rstrip()  # Remove whitespace & newline
                if cfg_line.endswith('\\'):
                    line += str(cfg_line[:-1])
                    continue
                else:
                    line = line+cfg_line

                # Find any defined dependency
                for macro_key in DEPENDENCIES:
                    if line.startswith(macro_key):
                        for dep_key in DEPENDENCIES[macro_key]:
                            if line.find(dep_key) != -1:
                                dep_pkg = DEPENDENCIES[macro_key][dep_key]
                                # Dependency package not already known
                                if deps.get(dep_pkg) is None:
                                    # Dependency package not installed
                                    deps[dep_pkg] = 0
                                    clone_pkg(dep_pkg)
                                    # Determine this dependency package's
                                    # dependencies and install them before
                                    # returning to install this package
                                    dep_pkgdir = os.path.join(WORKSPACE,
                                                              dep_pkg)
                                    deps = build_depends(dep_pkg,
                                                         dep_pkgdir,
                                                         deps)
                                else:
                                    # Dependency package known and installed
                                    if deps[dep_pkg] == 1:
                                        continue
                                    else:
                                        # Cyclic dependency failure
                                        raise Exception("Cyclic dependencies \
                                               found in "+pkg)
                line = ""

        # Build & install this package
        if deps[pkg] == 0:
            conf_flags = ""
            os.chdir(pkgdir)
            # Add any necessary configure flags for package
            for pkg_key in CONFIGURE_FLAGS:
                if pkg == pkg_key:
                    conf_flags = conf_flags+CONFIGURE_FLAGS[pkg_key]
            print pkgdir+"> ./bootstrap.sh"
            subprocess.check_call(['./bootstrap.sh'])
            print pkgdir+"> ./configure "+conf_flags
            subprocess.check_call(['./configure', conf_flags])
            print pkgdir+"> make"
            subprocess.check_call(['make'])
            print pkgdir+"> make install"
            subprocess.check_call(['make', 'install'])
            deps[pkg] = 1

    except IOError:
        raise Exception("ERROR: Unable to open " +
                        pkg + " configure.ac file in " + pkgdir)

    return deps


def main():
    if os.path.exists(os.path.join(WORKSPACE, UNIT_TEST_PKG)):
        # Determine dependencies and install them
        deps = dict()
        deps[UNIT_TEST_PKG] = 0
        deps = build_depends(UNIT_TEST_PKG,
                             os.path.join(WORKSPACE, UNIT_TEST_PKG),
                             deps)
        os.chdir(os.path.join(WORKSPACE, UNIT_TEST_PKG))
        # Run package unit tests
        print os.path.join(WORKSPACE, UNIT_TEST_PKG)+"> make check"
        subprocess.check_call(['make', 'check'])
    else:
        raise Exception("Unit test package workspace directory " +
                        os.path.join(WORKSPACE, UNIT_TEST_PKG) + " not found")

if __name__ == '__main__':
    rc = 0
    try:
        main()
    except Exception as e:
        print type(e)
        print e.args
        print e
        rc = -1
    # Must update all files' ownership to Jenkins' EXIT_USER before exit
    if EXIT_USER is not None:
        print "> chown -R "+EXIT_USER+" "+WORKSPACE
        subprocess.call(['chown', '-R', EXIT_USER, WORKSPACE])
    sys.exit(rc)
