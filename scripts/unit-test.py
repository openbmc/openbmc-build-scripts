#!/usr/bin/env python

"""
This script determines the given package's openbmc dependencies from its
configure.ac file where it downloads, configures, builds, and installs each of
these dependencies. Then the given package is configured, built, and installed
prior to executing its unit tests.
"""

from git import Repo
from urlparse import urljoin
from subprocess import check_call, call, CalledProcessError
import os
import sys
import argparse
import multiprocessing
import re
import platform


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
    pkg_dir = os.path.join(WORKSPACE, pkg)
    if os.path.exists(os.path.join(pkg_dir, '.git')):
        return pkg_dir
    pkg_repo = urljoin('https://gerrit.openbmc-project.xyz/openbmc/', pkg)
    os.mkdir(pkg_dir)
    printline(pkg_dir, "> git clone", pkg_repo, "./")
    return Repo.clone_from(pkg_repo, pkg_dir).working_dir


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

def get_autoconf_deps(pkgdir):
    """
    Parse the given 'configure.ac' file for package dependencies and return
    a list of the dependencies found. If the package is not autoconf it is just
    ignored.

    Parameter descriptions:
    pkgdir              Directory where package source is located
    """
    configure_ac = os.path.join(pkgdir, 'configure.ac')
    if not os.path.exists(configure_ac):
        return []

    with open(configure_ac, "rt") as f:
        return get_deps(f)

make_parallel = [
    'make',
    # Run enough jobs to saturate all the cpus
    '-j', str(multiprocessing.cpu_count()),
    # Don't start more jobs if the load avg is too high
    '-l', str(multiprocessing.cpu_count()),
    # Synchronize the output so logs aren't intermixed in stdout / stderr
    '-O',
]

def enFlag(flag, enabled):
    """
    Returns an configure flag as a string

    Parameters:
    flag                The name of the flag
    enabled             Whether the flag is enabled or disabled
    """
    return '--' + ('enable' if enabled else 'disable') + '-' + flag

def build_and_install(pkg, build_for_testing=False):
    """
    Builds and installs the package in the environment. Optionally
    builds the examples and test cases for package.

    Parameter description:
    pkg                 The package we are building
    build_for_testing   Enable options related to testing on the package?
    """
    pkgdir = os.path.join(WORKSPACE, pkg)
    # Build & install this package
    conf_flags = [
        enFlag('silent-rules', False),
        enFlag('examples', build_for_testing),
        enFlag('tests', build_for_testing),
        enFlag('code-coverage', build_for_testing),
        enFlag('valgrind', build_for_testing),
    ]
    os.chdir(pkgdir)
    # Add any necessary configure flags for package
    if CONFIGURE_FLAGS.get(pkg) is not None:
        conf_flags.extend(CONFIGURE_FLAGS.get(pkg))
    for bootstrap in ['bootstrap.sh', 'bootstrap', 'autogen.sh']:
        if os.path.exists(bootstrap):
            check_call_cmd(pkgdir, './' + bootstrap)
            break
    check_call_cmd(pkgdir, './configure', *conf_flags)
    check_call_cmd(pkgdir, *make_parallel)
    check_call_cmd(pkgdir, 'sudo', '-n', '--', *(make_parallel + [ 'install' ]))

def build_dep_tree(pkg, pkgdir, dep_added, head, dep_tree=None):
    """
    For each package(pkg), starting with the package to be unit tested,
    parse its 'configure.ac' file from within the package's directory(pkgdir)
    for each package dependency defined recursively doing the same thing
    on each package found as a dependency.

    Parameter descriptions:
    pkg                 Name of the package
    pkgdir              Directory where package source is located
    dep_added           Current dict of dependencies and added status
    head                Head node of the dependency tree
    dep_tree            Current dependency tree node
    """
    if not dep_tree:
        dep_tree = head

    with open("/depcache", "r") as depcache:
        cache = depcache.readline()

    # Read out pkg dependencies
    pkg_deps = []
    pkg_deps += get_autoconf_deps(pkgdir)

    for dep in pkg_deps:
        if dep in cache:
            continue
        # Dependency package not already known
        if dep_added.get(dep) is None:
            # Dependency package not added
            new_child = dep_tree.AddChild(dep)
            dep_added[dep] = False
            dep_pkgdir = clone_pkg(dep)
            # Determine this dependency package's
            # dependencies and add them before
            # returning to add this package
            dep_added = build_dep_tree(dep,
                                       dep_pkgdir,
                                       dep_added,
                                       head,
                                       new_child)
        else:
            # Dependency package known and added
            if dep_added[dep]:
                continue
            else:
                # Cyclic dependency failure
                raise Exception("Cyclic dependencies found in "+pkg)

    if not dep_added[pkg]:
        dep_added[pkg] = True

    return dep_added

def make_target_exists(target):
    """
    Runs a check against the makefile in the current directory to determine
    if the target exists so that it can be built.

    Parameter descriptions:
    target              The make target we are checking
    """
    try:
        cmd = [ 'make', '-n', target ]
        with open(os.devnull, 'w') as devnull:
            check_call(cmd, stdout=devnull, stderr=devnull)
        return True
    except CalledProcessError:
        return False

def run_unit_tests(top_dir):
    """
    Runs the unit tests for the package via `make check`

    Parameter descriptions:
    top_dir             The root directory of our project
    """
    try:
        cmd = make_parallel + [ 'check' ]
        for i in range(0, args.repeat):
            check_call_cmd(top_dir,  *cmd)
    except CalledProcessError:
        for root, _, files in os.walk(top_dir):
            if 'test-suite.log' not in files:
                continue
            check_call_cmd(root, 'cat', os.path.join(root, 'test-suite.log'))
        raise Exception('Unit tests failed')

def run_cppcheck(top_dir):
    try:
        # http://cppcheck.sourceforge.net/manual.pdf
        ignore_list = ['-i%s' % path for path in os.listdir(top_dir) \
                       if path.endswith('-src') or path.endswith('-build')]
        ignore_list.extend(('-itest', '-iscripts'))
        params = ['cppcheck', '-j', str(multiprocessing.cpu_count()),
                  '--enable=all']
        params.extend(ignore_list)
        params.append('.')

        check_call_cmd(top_dir, *params)
    except CalledProcessError:
        raise Exception('Cppcheck failed')

def maybe_run_valgrind(top_dir):
    """
    Potentially runs the unit tests through valgrind for the package
    via `make check-valgrind`. If the package does not have valgrind testing
    then it just skips over this.

    Parameter descriptions:
    top_dir             The root directory of our project
    """
    # Valgrind testing is currently broken by an aggressive strcmp optimization
    # that is inlined into optimized code for POWER by gcc 7+. Until we find
    # a workaround, just don't run valgrind tests on POWER.
    # https://github.com/openbmc/openbmc/issues/3315
    if re.match('ppc64', platform.machine()) is not None:
        return
    if not make_target_exists('check-valgrind'):
        return

    try:
        cmd = make_parallel + [ 'check-valgrind' ]
        check_call_cmd(top_dir,  *cmd)
    except CalledProcessError:
        for root, _, files in os.walk(top_dir):
            for f in files:
                if re.search('test-suite-[a-z]+.log', f) is None:
                    continue
                check_call_cmd(root, 'cat', os.path.join(root, f))
        raise Exception('Valgrind tests failed')

def maybe_run_coverage(top_dir):
    """
    Potentially runs the unit tests through code coverage for the package
    via `make check-code-coverage`. If the package does not have code coverage
    testing then it just skips over this.

    Parameter descriptions:
    top_dir             The root directory of our project
    """
    if not make_target_exists('check-code-coverage'):
        return

    # Actually run code coverage
    try:
        cmd = make_parallel + [ 'check-code-coverage' ]
        check_call_cmd(top_dir,  *cmd)
    except CalledProcessError:
        raise Exception('Code coverage failed')

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
            'blobs-ipmid': 'phosphor-ipmi-blobs',
            'sdbusplus': 'sdbusplus',
            'sdeventplus': 'sdeventplus',
            'gpioplus': 'gpioplus',
            'phosphor-logging/log.hpp': 'phosphor-logging',
        },
        'AC_PATH_PROG': {'sdbus++': 'sdbusplus'},
        'PKG_CHECK_MODULES': {
            'phosphor-dbus-interfaces': 'phosphor-dbus-interfaces',
            'openpower-dbus-interfaces': 'openpower-dbus-interfaces',
            'ibm-dbus-interfaces': 'ibm-dbus-interfaces',
            'sdbusplus': 'sdbusplus',
            'sdeventplus': 'sdeventplus',
            'gpioplus': 'gpioplus',
            'phosphor-logging': 'phosphor-logging',
            'phosphor-snmp': 'phosphor-snmp',
        },
    }

    # DEPENDENCIES_REGEX = [GIT REPO]:[REGEX STRING]
    DEPENDENCIES_REGEX = {
        'phosphor-logging': r'\S+-dbus-interfaces$'
    }

    # Set command line arguments
    parser = argparse.ArgumentParser()
    parser.add_argument("-w", "--workspace", dest="WORKSPACE", required=True,
                        help="Workspace directory location(i.e. /home)")
    parser.add_argument("-p", "--package", dest="PACKAGE", required=True,
                        help="OpenBMC package to be unit tested")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="Print additional package status messages")
    parser.add_argument("-r", "--repeat", help="Repeat tests N times",
                        type=int, default=1)
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

    # First validate code formatting if repo has style formatting files.
    # The format-code.sh checks for these files.
    CODE_SCAN_DIR = WORKSPACE + "/" + UNIT_TEST_PKG
    check_call_cmd(WORKSPACE, "./format-code.sh", CODE_SCAN_DIR)

    # Automake
    if os.path.isfile(CODE_SCAN_DIR + "/configure.ac"):
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
        # We don't want to treat our package as a dependency
        install_list.remove(UNIT_TEST_PKG)
        # install reordered dependencies
        for dep in install_list:
            build_and_install(dep, False)
        top_dir = os.path.join(WORKSPACE, UNIT_TEST_PKG)
        os.chdir(top_dir)
        # Refresh dynamic linker run time bindings for dependencies
        check_call_cmd(top_dir, 'sudo', '-n', '--', 'ldconfig')
        # Run package unit tests
        build_and_install(UNIT_TEST_PKG, True)
        run_unit_tests(top_dir)
        maybe_run_valgrind(top_dir)
        maybe_run_coverage(top_dir)
        run_cppcheck(top_dir)

        os.umask(prev_umask)

    # Cmake
    elif os.path.isfile(CODE_SCAN_DIR + "/CMakeLists.txt"):
        top_dir = os.path.join(WORKSPACE, UNIT_TEST_PKG)
        os.chdir(top_dir)
        check_call_cmd(top_dir, 'cmake', '.')
        check_call_cmd(top_dir, 'cmake', '--build', '.', '--', '-j',
                       str(multiprocessing.cpu_count()))
        if make_target_exists('test'):
            check_call_cmd(top_dir, 'ctest', '.')
        maybe_run_valgrind(top_dir)
        maybe_run_coverage(top_dir)
        run_cppcheck(top_dir)

    else:
        print "Not a supported repo for CI Tests, exit"
        quit()
