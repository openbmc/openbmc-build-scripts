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
import re


class DepTree():
    """
    Represents package dependency tree, where each node is a DepTree with a
    name and DepTree children.
    """

    def __init__(self, name):
        """
        Create new DepTree.

        Parameter descriptions:
        name               Name of new tree node.
        """
        self.name = name
        self.children = list()

    def AddChild(self, name):
        """
        Add new child node to current node.

        Parameter descriptions:
        name               Name of new child
        """
        new_child = DepTree(name)
        self.children.append(new_child)
        return new_child

    def AddChildNode(self, node):
        """
        Add existing child node to current node.

        Parameter descriptions:
        node               Tree node to add
        """
        self.children.append(node)

    def RemoveChild(self, name):
        """
        Remove child node.

        Parameter descriptions:
        name               Name of child to remove
        """
        for child in self.children:
            if child.name == name:
                self.children.remove(child)
                return

    def GetNode(self, name):
        """
        Return node with matching name. Return None if not found.

        Parameter descriptions:
        name               Name of node to return
        """
        if self.name == name:
            return self
        for child in self.children:
            node = child.GetNode(name)
            if node:
                return node
        return None

    def GetParentNode(self, name, parent_node=None):
        """
        Return parent of node with matching name. Return none if not found.

        Parameter descriptions:
        name               Name of node to get parent of
        parent_node        Parent of current node
        """
        if self.name == name:
            return parent_node
        for child in self.children:
            found_node = child.GetParentNode(name, self)
            if found_node:
                return found_node
        return None

    def GetPath(self, name, path=None):
        """
        Return list of node names from head to matching name.
        Return None if not found.

        Parameter descriptions:
        name               Name of node
        path               List of node names from head to current node
        """
        if not path:
            path = []
        if self.name == name:
            path.append(self.name)
            return path
        for child in self.children:
            match = child.GetPath(name, path + [self.name])
            if match:
                return match
        return None

    def GetPathRegex(self, name, regex_str, path=None):
        """
        Return list of node paths that end in name, or match regex_str.
        Return empty list if not found.

        Parameter descriptions:
        name               Name of node to search for
        regex_str          Regex string to match node names
        path               Path of node names from head to current node
        """
        new_paths = []
        if not path:
            path = []
        match = re.match(regex_str, self.name)
        if (self.name == name) or (match):
            new_paths.append(path + [self.name])
        for child in self.children:
            return_paths = None
            full_path = path + [self.name]
            return_paths = child.GetPathRegex(name, regex_str, full_path)
            for i in return_paths:
                new_paths.append(i)
        return new_paths

    def MoveNode(self, from_name, to_name):
        """
        Mode existing from_name node to become child of to_name node.

        Parameter descriptions:
        from_name          Name of node to make a child of to_name
        to_name            Name of node to make parent of from_name
        """
        parent_from_node = self.GetParentNode(from_name)
        from_node = self.GetNode(from_name)
        parent_from_node.RemoveChild(from_name)
        to_node = self.GetNode(to_name)
        to_node.AddChildNode(from_node)

    def ReorderDeps(self, name, regex_str):
        """
        Reorder dependency tree.  If tree contains nodes with names that
        match 'name' and 'regex_str', move 'regex_str' nodes that are
        to the right of 'name' node, so that they become children of the
        'name' node.

        Parameter descriptions:
        name               Name of node to look for
        regex_str          Regex string to match names to
        """
        name_path = self.GetPath(name)
        if not name_path:
            return
        paths = self.GetPathRegex(name, regex_str)
        is_name_in_paths = False
        name_index = 0
        for i in range(len(paths)):
            path = paths[i]
            if path[-1] == name:
                is_name_in_paths = True
                name_index = i
                break
        if not is_name_in_paths:
            return
        for i in range(name_index + 1, len(paths)):
            path = paths[i]
            if name in path:
                continue
            from_name = path[-1]
            self.MoveNode(from_name, name)

    def GetInstallList(self):
        """
        Return post-order list of node names.

        Parameter descriptions:
        """
        install_list = []
        for child in self.children:
            child_install_list = child.GetInstallList()
            install_list.extend(child_install_list)
        install_list.append(self.name)
        return install_list

    def PrintTree(self, level=0):
        """
        Print pre-order node names with indentation denoting node depth level.

        Parameter descriptions:
        level              Current depth level
        """
        INDENT_PER_LEVEL = 4
        print ' ' * (level * INDENT_PER_LEVEL) + self.name
        for child in self.children:
            child.PrintTree(level + 1)


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
    deps = list(dep_pkgs)

    return deps


def install_deps(dep_list):
    """
    Install each package in the ordered dep_list.

    Parameter descriptions:
    dep_list            Ordered list of dependencies
    """
    for pkg in dep_list:
        pkgdir = os.path.join(WORKSPACE, pkg)
        # Build & install this package
        conf_flags = []
        os.chdir(pkgdir)
        # Add any necessary configure flags for package
        if CONFIGURE_FLAGS.get(pkg) is not None:
            conf_flags.extend(CONFIGURE_FLAGS.get(pkg))
        check_call_cmd(pkgdir, './bootstrap.sh')
        check_call_cmd(pkgdir, './configure', *conf_flags)
        check_call_cmd(pkgdir, 'make')
        check_call_cmd(pkgdir, 'make', 'install')


def build_dep_tree(pkg, pkgdir, dep_added, head, dep_tree=None):
    """
    For each package(pkg), starting with the package to be unit tested,
    parse its 'configure.ac' file from within the package's directory(pkgdir)
    for each package dependency defined recursively doing the same thing
    on each package found as a dependency.

    Parameter descriptions:
    pkg                 Name of the package
    pkgdir              Directory where package source is located
    dep_added           Current list of dependencies and added status
    head                Head node of the dependency tree
    dep_tree            Current dependency tree node
    """
    if not dep_tree:
        dep_tree = head
    os.chdir(pkgdir)
    # Open package's configure.ac
    with open("configure.ac", "rt") as configure_ac:
        # Retrieve dependency list from package's configure.ac
        configure_ac_deps = get_deps(configure_ac)
        for dep_pkg in configure_ac_deps:
            # Dependency package not already known
            if dep_added.get(dep_pkg) is None:
                # Dependency package not added
                new_child = dep_tree.AddChild(dep_pkg)
                dep_added[dep_pkg] = False
                dep_repo = clone_pkg(dep_pkg)
                # Determine this dependency package's
                # dependencies and add them before
                # returning to add this package
                dep_pkgdir = os.path.join(WORKSPACE, dep_pkg)
                dep_added = build_dep_tree(dep_pkg,
                                           dep_repo.working_dir,
                                           dep_added,
                                           head,
                                           new_child)
            else:
                # Dependency package known and added
                if dep_added[dep_pkg]:
                    continue
                else:
                    # Cyclic dependency failure
                    raise Exception("Cyclic dependencies found in "+pkg)

    if not dep_added[pkg]:
        dep_added[pkg] = True

    return dep_added


if __name__ == '__main__':
    # CONFIGURE_FLAGS = [GIT REPO]:[CONFIGURE FLAGS]
    CONFIGURE_FLAGS = {
        'phosphor-objmgr': ['--enable-unpatched-systemd'],
        'sdbusplus': ['--enable-transaction'],
        'phosphor-logging':
        ['--enable-metadata-processing',
         'YAML_DIR=/usr/local/share/phosphor-dbus-yaml/yaml']
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

    # DEPENDENCIES_REGEX = [GIT REPO]:[REGEX STRING]
    DEPENDENCIES_REGEX = {
        'phosphor-logging': '\S+-dbus-interfaces$'
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

    # First validate code formattting if repo has style formatting files.
    # The format-code.sh checks for these files.
    CODE_SCAN_DIR = WORKSPACE + "/" + UNIT_TEST_PKG
    check_call_cmd(WORKSPACE, "./format-code.sh", CODE_SCAN_DIR)

    # Next verify this is an supported repo, if not just exit
    # Currently this script only support Automake
    if not os.path.isfile(CODE_SCAN_DIR + "/configure.ac"):
        print "Not a supported repo for CI Tests, exit"
        quit()

    prev_umask = os.umask(000)
    # Determine dependencies and add them
    dep_added = dict()
    dep_added[UNIT_TEST_PKG] = False
    # Create dependency tree
    dep_tree = DepTree(UNIT_TEST_PKG)
    build_dep_tree(UNIT_TEST_PKG,
                   os.path.join(WORKSPACE, UNIT_TEST_PKG),
                   dep_added,
                   dep_tree)

    # Reorder Dependency Tree
    for pkg_name, regex_str in DEPENDENCIES_REGEX.iteritems():
        dep_tree.ReorderDeps(pkg_name, regex_str)
    if args.verbose:
        dep_tree.PrintTree()
    install_list = dep_tree.GetInstallList()
    # install reordered dependencies
    install_deps(install_list)
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
