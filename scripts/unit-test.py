#!/usr/bin/env python

"""
This script determines the given package's openbmc dependencies from its
configure.ac file where it downloads, configures, builds, and installs each of
these dependencies. Then the given package is configured, built, and installed
prior to executing its unit tests.
"""

from urlparse import urljoin
import os
import sys


def clone_pkg(pkg):
    pkg_repo = urljoin('https://gerrit.openbmc-project.xyz/openbmc/', pkg)
    os.chdir(WORKSPACE)
    os.system("git clone "+pkg_repo)  # TODO Replace with subprocess call


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
    with open("configure.ac", "rt") as infile:
        for line in infile:  # TODO Handle line breaks
            # Find any defined dependency
            for macro_key in DEPENDENCIES:
                if not line.startswith(macro_key):
                    continue
                for dep_key in DEPENDENCIES[macro_key]:
                    if line.find(dep_key) == -1:
                        continue
                    dep_pkg = DEPENDENCIES[macro_key][dep_key]
                    # Dependency package not already known
                    if dep_installed.get(dep_pkg) is None:
                        # Dependency package not installed
                        dep_installed[dep_pkg] = False
                        clone_pkg(dep_pkg)
                        # Determine this dependency package's
                        # dependencies and install them before
                        # returning to install this package
                        dep_pkgdir = os.path.join(WORKSPACE, dep_pkg)
                        dep_installed = build_depends(dep_pkg, dep_pkgdir,
                                                      dep_installed)
                    else:
                        # Dependency package known and installed
                        if dep_installed[dep_pkg]:
                            continue
                        else:
                            # Cyclic dependency failure
                            raise Exception("Cyclic dependencies \
                                   found in "+pkg)

    # Build & install this package
    if not dep_installed[pkg]:
        conf_flags = ""
        os.chdir(pkgdir)
        # Add any necessary configure flags for package
        if CONFIGURE_FLAGS.get(pkg) is not None:
            conf_flags = " ".join(CONFIGURE_FLAGS.get(pkg))
        os.system("./bootstrap.sh && ./configure " +
                  conf_flags + "&& make && make install")
        dep_installed[pkg] = True

    return dep_installed


if __name__ == '__main__':
    # CONFIGURE_FLAGS = [GIT REPO]:[CONFIGURE FLAGS]
    CONFIGURE_FLAGS = {
        'phosphor-objmgr': ['--enable-unpatched-systemd']
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

    prev_umask = os.umask(000)
    # Determine dependencies and install them
    dep_installed = dict()
    dep_installed[UNIT_TEST_PKG] = False
    dep_installed = build_depends(UNIT_TEST_PKG,
                                  os.path.join(WORKSPACE, UNIT_TEST_PKG),
                                  dep_installed)
    os.chdir(os.path.join(WORKSPACE, UNIT_TEST_PKG))
    # Run package unit tests
    os.system("make check")  # TODO Verify all fails halt Jenkins
    os.umask(prev_umask)
