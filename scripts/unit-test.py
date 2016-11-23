#!/usr/bin/env python
#
# Execute the given repository's unit tests
#

import os
import sys
import argparse

rc = 0

# CONFIGURE_FLAGS = [GIT REPO]:[CONFIGURE FLAGS]
CONFIGURE_FLAGS = {
    'phosphor-objmgr:--enable-unpatched-systemd'
}

# DEPENDENCIES = [MACRO]:[library/header]:[GIT REPO]
DEPENDENCIES = {
    'AC_CHECK_LIB:mapper:phosphor-objmgr',
    'AC_CHECK_HEADER:host-ipmid/ipmid-api.h:phosphor-host-ipmid'
}

# Get workspace directory (package source to be tested)
WORKSPACE = os.environ.get('WORKSPACE')
if WORKSPACE is None:
    print "ERROR: Environment variable 'WORKSPACE' not set"
    rc = -1

# Determine package name
UNIT_TEST_PKG = os.environ.get('UNIT_TEST_PKG')

# Retrieve user to update all workspace files ownership to
EXIT_USER = os.environ.get('EXIT_USER')
if EXIT_USER is None:
    print "WARNING: EXIT_USER variable not set, attempting to use ${USER}"
    EXIT_USER = os.environ.get('USER')


def clone_pkg(pkg):
    pkg_repo = "https://gerrit.openbmc-project.xyz/openbmc/"+pkg
    os.chdir(WORKSPACE)
    os.system("git clone "+pkg_repo)  # TODO Replace with subprocess call


def build_depends(pkg=None, pkgdir=None, deps=None):
    os.chdir(pkgdir)
    try:
        # Open configure.ac
        with open("configure.ac", "rt") as infile:
            for line in infile:  # TODO Handle line breaks
                # End of file
                if not line:
                    break

                # Find new dependency
                for dep in DEPENDENCIES:
                    dep = dep.split(":")
                    if (line.startswith(dep[0])) and (line.find(dep[1]) != -1):
                        if dep[2] not in deps:
                            deps[dep[2]] = 0
                            clone_pkg(dep[2])
                            deps = build_depends(dep[2],
                                                 WORKSPACE+dep[2],
                                                 deps)
                        else:
                            if deps[dep[2]] == 0:
                                clone_pkg(dep[2])
                                deps = build_depends(dep[2],
                                                     WORKSPACE+dep[2],
                                                     deps)
                            else:
                                continue

        # Build & install current package
        infile.close
        if deps[pkg] == 0:
            conf_flags = ""
            os.chdir(pkgdir)
            for flag in CONFIGURE_FLAGS:
                flag = flag.split(":")
                if pkg == flag[0]:
                    conf_flags = conf_flags+flag[1]+" "
            os.system("./bootstrap.sh && ./configure " +
                      conf_flags + "&& make && make install")
            deps[pkg] = 1

    except (IOError):
        print "ERROR: Unable to open "+pkg+" configure.ac file in "+pkgdir

    return deps

if rc == 0 and os.path.exists(WORKSPACE+UNIT_TEST_PKG):
    # Determine dependencies and install them
    deps = dict()
    deps[UNIT_TEST_PKG] = 0
    deps = build_depends(UNIT_TEST_PKG, WORKSPACE+UNIT_TEST_PKG, deps)
    os.chdir(WORKSPACE+UNIT_TEST_PKG)
    # Run package unit tests
    os.system("make check")  # TODO Verify all fails halt Jenkins
else:
    print "ERROR: Unit test package workspace directory not found"
    rc = -1

# Must always update all files' ownership before exit
os.system("chown -R "+EXIT_USER+" "+WORKSPACE)
sys.exit(rc)
