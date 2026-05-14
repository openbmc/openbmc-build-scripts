#!/usr/bin/env python3

"""
This script determines the given package's openbmc dependencies from its
configure.ac file where it downloads, configures, builds, and installs each of
these dependencies. Then the given package is configured, built, and installed
prior to executing its unit tests.
"""

import argparse
import json
import multiprocessing
import os
import platform
import re
import resource
import shutil
import subprocess
import sys
import tempfile
from subprocess import CalledProcessError, check_call
from tempfile import TemporaryDirectory
from urllib.parse import urljoin

from git import Repo
from git.exc import GitCommandError

# interpreter is not used directly but this resolves dependency ordering
# that would be broken if we didn't include it.
from mesonbuild import interpreter  # noqa: F401
from mesonbuild import optinterpreter, options
from mesonbuild.mesonlib import version_compare as meson_version_compare
from mesonbuild.options import OptionKey, OptionStore


class DepTree:
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
        print(" " * (level * INDENT_PER_LEVEL) + self.name)
        for child in self.children:
            child.PrintTree(level + 1)


def check_call_cmd(*cmd, **kwargs):
    """
    Verbose prints the directory location the given command is called from and
    the command, then executes the command using check_call.

    Parameter descriptions:
    dir                 Directory location command is to be called from
    cmd                 List of parameters constructing the complete command
    """
    printline(os.getcwd(), ">", " ".join(cmd))
    check_call(cmd, **kwargs)


def clone_pkg(pkg, branch):
    """
    Clone the given openbmc package's git repository from gerrit into
    the WORKSPACE location

    Parameter descriptions:
    pkg                 Name of the package to clone
    branch              Branch to clone from pkg
    """
    pkg_dir = os.path.join(WORKSPACE, pkg)
    if os.path.exists(os.path.join(pkg_dir, ".git")):
        return pkg_dir
    pkg_repo = urljoin("https://gerrit.openbmc.org/openbmc/", pkg)
    os.mkdir(pkg_dir)
    printline(pkg_dir, "> git clone", pkg_repo, branch, "./")
    try:
        # first try the branch
        clone = Repo.clone_from(pkg_repo, pkg_dir, branch=branch)
        repo_inst = clone.working_dir
    except GitCommandError:
        printline("Input branch not found, default to master")
        clone = Repo.clone_from(pkg_repo, pkg_dir, branch="master")
        repo_inst = clone.working_dir
    return repo_inst


def make_target_exists(target):
    """
    Runs a check against the makefile in the current directory to determine
    if the target exists so that it can be built.

    Parameter descriptions:
    target              The make target we are checking
    """
    try:
        cmd = ["make", "-n", target]
        with open(os.devnull, "w") as devnull:
            check_call(cmd, stdout=devnull, stderr=devnull)
        return True
    except CalledProcessError:
        return False


make_parallel = [
    "make",
    # Run enough jobs to saturate all the cpus
    "-j",
    str(multiprocessing.cpu_count()),
    # Don't start more jobs if the load avg is too high
    "-l",
    str(multiprocessing.cpu_count()),
    # Synchronize the output so logs aren't intermixed in stdout / stderr
    "-O",
]


def build_and_install(name, build_for_testing=False):
    """
    Builds and installs the package in the environment. Optionally
    builds the examples and test cases for package.

    Parameter description:
    name                The name of the package we are building
    build_for_testing   Enable options related to testing on the package?
    """
    os.chdir(os.path.join(WORKSPACE, name))

    # Refresh dynamic linker run time bindings for dependencies
    check_call_cmd("sudo", "-n", "--", "ldconfig")

    pkg = Package()
    if build_for_testing:
        pkg.test()
    else:
        pkg.install()


def build_dep_tree(name, pkgdir, dep_added, head, branch, dep_tree=None):
    """
    For each package (name), starting with the package to be unit tested,
    extract its dependencies. For each package dependency defined, recursively
    apply the same strategy

    Parameter descriptions:
    name                Name of the package
    pkgdir              Directory where package source is located
    dep_added           Current dict of dependencies and added status
    head                Head node of the dependency tree
    branch              Branch to clone from pkg
    dep_tree            Current dependency tree node
    """
    if not dep_tree:
        dep_tree = head

    with open("/tmp/depcache", "r") as depcache:
        cache = depcache.readline()

    # Read out pkg dependencies
    pkg = Package(name, pkgdir)

    build = pkg.build_system()
    if not build:
        raise Exception(f"Unable to find build system for {name}.")

    for dep in set(build.dependencies()):
        if dep in cache:
            continue
        # Dependency package not already known
        if dep_added.get(dep) is None:
            print(f"Adding {dep} dependency to {name}.")
            # Dependency package not added
            new_child = dep_tree.AddChild(dep)
            dep_added[dep] = False
            dep_pkgdir = clone_pkg(dep, branch)
            # Determine this dependency package's
            # dependencies and add them before
            # returning to add this package
            dep_added = build_dep_tree(
                dep, dep_pkgdir, dep_added, head, branch, new_child
            )
        else:
            # Dependency package known and added
            if dep_added[dep]:
                continue
            else:
                # Cyclic dependency failure
                raise Exception("Cyclic dependencies found in " + name)

    if not dep_added[name]:
        dep_added[name] = True

    return dep_added


def valgrind_rlimit_nofile(soft=2048, hard=4096):
    resource.setrlimit(resource.RLIMIT_NOFILE, (soft, hard))


def is_valgrind_safe():
    """
    Returns whether it is safe to run valgrind on our platform
    """
    with tempfile.TemporaryDirectory() as temp:
        src = os.path.join(temp, "unit-test-vg.c")
        exe = os.path.join(temp, "unit-test-vg")
        with open(src, "w") as h:
            h.write("#include <errno.h>\n")
            h.write("#include <stdio.h>\n")
            h.write("#include <stdlib.h>\n")
            h.write("#include <string.h>\n")
            h.write("int main() {\n")
            h.write("char *heap_str = malloc(16);\n")
            h.write('strcpy(heap_str, "RandString");\n')
            h.write('int res = strcmp("RandString", heap_str);\n')
            h.write("free(heap_str);\n")
            h.write("char errstr[64];\n")
            h.write("strerror_r(EINVAL, errstr, sizeof(errstr));\n")
            h.write('printf("%s\\n", errstr);\n')
            h.write("return res;\n")
            h.write("}\n")
        check_call(
            ["gcc", "-O2", "-o", exe, src],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            check_call(
                ["valgrind", "--error-exitcode=99", exe],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                preexec_fn=valgrind_rlimit_nofile,
            )
        except CalledProcessError:
            sys.stderr.write("###### Platform is not valgrind safe ######\n")
            return False
        return True


def is_sanitize_safe():
    """
    Returns whether it is safe to run sanitizers on our platform
    """
    src = "unit-test-sanitize.c"
    exe = "./unit-test-sanitize"
    with open(src, "w") as h:
        h.write("int main() { return 0; }\n")
    try:
        with open(os.devnull, "w") as devnull:
            check_call(
                [
                    "gcc",
                    "-O2",
                    "-fsanitize=address",
                    "-fsanitize=undefined",
                    "-o",
                    exe,
                    src,
                ],
                stdout=devnull,
                stderr=devnull,
            )
            check_call([exe], stdout=devnull, stderr=devnull)

        # TODO: Sanitizer not working on ppc64le
        # https://github.com/openbmc/openbmc-build-scripts/issues/31
        if platform.processor() == "ppc64le":
            sys.stderr.write("###### ppc64le is not sanitize safe ######\n")
            return False
        else:
            return True
    except Exception:
        sys.stderr.write("###### Platform is not sanitize safe ######\n")
        return False
    finally:
        os.remove(src)
        os.remove(exe)


def maybe_make_valgrind():
    """
    Potentially runs the unit tests through valgrind for the package
    via `make check-valgrind`. If the package does not have valgrind testing
    then it just skips over this.
    """
    # Valgrind testing is currently broken by an aggressive strcmp optimization
    # that is inlined into optimized code for POWER by gcc 7+. Until we find
    # a workaround, just don't run valgrind tests on POWER.
    # https://github.com/openbmc/openbmc/issues/3315
    if not is_valgrind_safe():
        sys.stderr.write("###### Skipping valgrind ######\n")
        return
    if not make_target_exists("check-valgrind"):
        return

    try:
        cmd = make_parallel + ["check-valgrind"]
        check_call_cmd(*cmd, preexec_fn=valgrind_rlimit_nofile)
    except CalledProcessError:
        for root, _, files in os.walk(os.getcwd()):
            for f in files:
                if re.search("test-suite-[a-z]+.log", f) is None:
                    continue
                check_call_cmd("cat", os.path.join(root, f))
        raise Exception("Valgrind tests failed")


def maybe_make_coverage():
    """
    Potentially runs the unit tests through code coverage for the package
    via `make check-code-coverage`. If the package does not have code coverage
    testing then it just skips over this.
    """
    if not make_target_exists("check-code-coverage"):
        return

    # Actually run code coverage
    try:
        cmd = make_parallel + ["check-code-coverage"]
        check_call_cmd(*cmd)
    except CalledProcessError:
        raise Exception("Code coverage failed")


class BuildSystem(object):
    """
    Build systems generally provide the means to configure, build, install and
    test software. The BuildSystem class defines a set of interfaces on top of
    which Autotools, Meson, CMake and possibly other build system drivers can
    be implemented, separating out the phases to control whether a package
    should merely be installed or also tested and analyzed.
    """

    def __init__(self, package, path):
        """Initialise the driver with properties independent of the build
        system

        Keyword arguments:
        package: The name of the package. Derived from the path if None
        path: The path to the package. Set to the working directory if None
        """
        self.path = "." if not path else path
        realpath = os.path.realpath(self.path)
        self.package = package if package else os.path.basename(realpath)
        self.build_for_testing = False

    def probe(self):
        """Test if the build system driver can be applied to the package

        Return True if the driver can drive the package's build system,
        otherwise False.

        Generally probe() is implemented by testing for the presence of the
        build system's configuration file(s).
        """
        raise NotImplementedError

    def dependencies(self):
        """Provide the package's dependencies

        Returns a list of dependencies. If no dependencies are required then an
        empty list must be returned.

        Generally dependencies() is implemented by analysing and extracting the
        data from the build system configuration.
        """
        raise NotImplementedError

    def configure(self, build_for_testing):
        """Configure the source ready for building

        Should raise an exception if configuration failed.

        Keyword arguments:
        build_for_testing: Mark the package as being built for testing rather
                           than for installation as a dependency for the
                           package under test. Setting to True generally
                           implies that the package will be configured to build
                           with debug information, at a low level of
                           optimisation and possibly with sanitizers enabled.

        Generally configure() is implemented by invoking the build system
        tooling to generate Makefiles or equivalent.
        """
        raise NotImplementedError

    def build(self):
        """Build the software ready for installation and/or testing

        Should raise an exception if the build fails

        Generally build() is implemented by invoking `make` or `ninja`.
        """
        raise NotImplementedError

    def install(self):
        """Install the software ready for use

        Should raise an exception if installation fails

        Like build(), install() is generally implemented by invoking `make` or
        `ninja`.
        """
        raise NotImplementedError

    def test(self):
        """Build and run the test suite associated with the package

        Should raise an exception if the build or testing fails.

        Like install(), test() is generally implemented by invoking `make` or
        `ninja`.
        """
        raise NotImplementedError

    def analyze(self):
        """Run any supported analysis tools over the codebase

        Should raise an exception if analysis fails.

        Some analysis tools such as scan-build need injection into the build
        system. analyze() provides the necessary hook to implement such
        behaviour. Analyzers independent of the build system can also be
        specified here but at the cost of possible duplication of code between
        the build system driver implementations.
        """
        raise NotImplementedError


class Autotools(BuildSystem):
    def __init__(self, package=None, path=None):
        super(Autotools, self).__init__(package, path)

    def probe(self):
        return os.path.isfile(os.path.join(self.path, "configure.ac"))

    def dependencies(self):
        configure_ac = os.path.join(self.path, "configure.ac")

        contents = ""
        # Prepend some special function overrides so we can parse out
        # dependencies
        for macro in DEPENDENCIES.keys():
            contents += (
                "m4_define(["
                + macro
                + "], ["
                + macro
                + "_START$"
                + str(DEPENDENCIES_OFFSET[macro] + 1)
                + macro
                + "_END])\n"
            )
        with open(configure_ac, "rt") as f:
            contents += f.read()

        autoconf_cmdline = ["autoconf", "-Wno-undefined", "-"]
        autoconf_process = subprocess.Popen(
            autoconf_cmdline,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        document = contents.encode("utf-8")
        stdout, stderr = autoconf_process.communicate(input=document)
        if not stdout:
            print(stderr)
            raise Exception("Failed to run autoconf for parsing dependencies")

        # Parse out all of the dependency text
        matches = []
        for macro in DEPENDENCIES.keys():
            pattern = "(" + macro + ")_START(.*?)" + macro + "_END"
            for match in re.compile(pattern).finditer(stdout.decode("utf-8")):
                matches.append((match.group(1), match.group(2)))

        # Look up dependencies from the text
        found_deps = []
        for macro, deptext in matches:
            for potential_dep in deptext.split(" "):
                for known_dep in DEPENDENCIES[macro].keys():
                    if potential_dep.startswith(known_dep):
                        found_deps.append(DEPENDENCIES[macro][known_dep])

        return found_deps

    def _configure_feature(self, flag, enabled):
        """
        Returns an configure flag as a string

        Parameters:
        flag                The name of the flag
        enabled             Whether the flag is enabled or disabled
        """
        return "--" + ("enable" if enabled else "disable") + "-" + flag

    def configure(self, build_for_testing):
        self.build_for_testing = build_for_testing
        conf_flags = [
            self._configure_feature("silent-rules", False),
            self._configure_feature("examples", build_for_testing),
            self._configure_feature("tests", build_for_testing),
            self._configure_feature("itests", INTEGRATION_TEST),
        ]
        conf_flags.extend(
            [
                self._configure_feature("code-coverage", False),
                self._configure_feature("valgrind", build_for_testing),
            ]
        )
        # Add any necessary configure flags for package
        if CONFIGURE_FLAGS.get(self.package) is not None:
            conf_flags.extend(CONFIGURE_FLAGS.get(self.package))
        for bootstrap in ["bootstrap.sh", "bootstrap", "autogen.sh"]:
            if os.path.exists(bootstrap):
                check_call_cmd("./" + bootstrap)
                break
        check_call_cmd("./configure", *conf_flags)

    def build(self):
        check_call_cmd(*make_parallel)

    def install(self):
        check_call_cmd("sudo", "-n", "--", *(make_parallel + ["install"]))
        check_call_cmd("sudo", "-n", "--", "ldconfig")

    def test(self):
        try:
            cmd = make_parallel + ["check"]
            for i in range(0, args.repeat):
                check_call_cmd(*cmd)

            maybe_make_valgrind()
            maybe_make_coverage()
        except CalledProcessError:
            for root, _, files in os.walk(os.getcwd()):
                if "test-suite.log" not in files:
                    continue
                check_call_cmd("cat", os.path.join(root, "test-suite.log"))
            raise Exception("Unit tests failed")

    def analyze(self):
        pass


class CMake(BuildSystem):
    def __init__(self, package=None, path=None):
        super(CMake, self).__init__(package, path)

    def probe(self):
        return os.path.isfile(os.path.join(self.path, "CMakeLists.txt"))

    def dependencies(self):
        return []

    def configure(self, build_for_testing):
        self.build_for_testing = build_for_testing
        if INTEGRATION_TEST:
            check_call_cmd(
                "cmake",
                "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
                "-DCMAKE_CXX_FLAGS='-DBOOST_USE_VALGRIND'",
                "-DITESTS=ON",
                ".",
            )
        else:
            check_call_cmd(
                "cmake",
                "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
                "-DCMAKE_CXX_FLAGS='-DBOOST_USE_VALGRIND'",
                ".",
            )

    def build(self):
        check_call_cmd(
            "cmake",
            "--build",
            ".",
            "--",
            "-j",
            str(multiprocessing.cpu_count()),
        )

    def install(self):
        check_call_cmd("sudo", "cmake", "--install", ".")
        check_call_cmd("sudo", "-n", "--", "ldconfig")

    def test(self):
        if make_target_exists("test"):
            check_call_cmd("ctest", ".")

    def analyze(self):
        if os.path.isfile(".clang-tidy"):
            with TemporaryDirectory(prefix="build", dir=".") as build_dir:
                # clang-tidy needs to run on a clang-specific build
                check_call_cmd(
                    "cmake",
                    "-DCMAKE_C_COMPILER=clang",
                    "-DCMAKE_CXX_COMPILER=clang++",
                    "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
                    "-H.",
                    "-B" + build_dir,
                )

                check_call_cmd(
                    "run-clang-tidy", "-header-filter=.*", "-p", build_dir
                )

        maybe_make_valgrind()
        maybe_make_coverage()


class Meson(BuildSystem):
    @staticmethod
    def _project_name(path):
        doc = subprocess.check_output(
            ["meson", "introspect", "--projectinfo", path],
            stderr=subprocess.STDOUT,
        ).decode("utf-8")
        return json.loads(doc)["descriptive_name"]

    def __init__(self, package=None, path=None):
        super(Meson, self).__init__(package, path)

    def probe(self):
        return os.path.isfile(os.path.join(self.path, "meson.build"))

    def dependencies(self):
        meson_build = os.path.join(self.path, "meson.build")
        if not os.path.exists(meson_build):
            return []

        found_deps = []
        for root, dirs, files in os.walk(self.path):
            if "meson.build" not in files:
                continue
            with open(os.path.join(root, "meson.build"), "rt") as f:
                build_contents = f.read()
            pattern = r"dependency\('([^']*)'.*?\),?"
            for match in re.finditer(pattern, build_contents):
                group = match.group(1)
                maybe_dep = DEPENDENCIES["PKG_CHECK_MODULES"].get(group)
                if maybe_dep is not None:
                    found_deps.append(maybe_dep)

        return found_deps

    def _parse_options(self, options_file):
        """
        Returns a set of options defined in the provides meson_options.txt file

        Parameters:
        options_file        The file containing options
        """
        store = OptionStore(is_cross=False)
        oi = optinterpreter.OptionInterpreter(store, None)
        oi.process(options_file)
        return oi.options

    def _configure_boolean(self, val):
        """
        Returns the meson flag which signifies the value

        True is true which requires the boolean.
        False is false which disables the boolean.

        Parameters:
        val                 The value being converted
        """
        if val is True:
            return "true"
        elif val is False:
            return "false"
        else:
            raise Exception("Bad meson boolean value")

    def _configure_feature(self, val):
        """
        Returns the meson flag which signifies the value

        True is enabled which requires the feature.
        False is disabled which disables the feature.
        None is auto which autodetects the feature.

        Parameters:
        val                 The value being converted
        """
        if val is True:
            return "enabled"
        elif val is False:
            return "disabled"
        elif val is None:
            return "auto"
        else:
            raise Exception("Bad meson feature value")

    def _configure_option(self, opts, key, val):
        """
        Returns the meson flag which signifies the value
        based on the type of the opt

        Parameters:
        opt                 The meson option which we are setting
        val                 The value being converted
        """
        if isinstance(opts[key], options.UserBooleanOption):
            str_val = self._configure_boolean(val)
        elif isinstance(opts[key], options.UserFeatureOption):
            str_val = self._configure_feature(val)
        else:
            raise Exception("Unknown meson option type")
        return "-D{}={}".format(key, str_val)

    def get_configure_flags(self, build_for_testing):
        self.build_for_testing = build_for_testing
        meson_options = {}
        if os.path.exists("meson.options"):
            meson_options = self._parse_options("meson.options")
        elif os.path.exists("meson_options.txt"):
            meson_options = self._parse_options("meson_options.txt")
        meson_flags = [
            "-Db_colorout=never",
            "-Dwerror=true",
            "-Dwarning_level=3",
            "-Dcpp_args='-DBOOST_USE_VALGRIND'",
        ]
        if build_for_testing:
            # -Ddebug=true -Doptimization=g is helpful for abi-dumper but isn't a combination that
            # is supported by meson's build types. Configure it manually.
            meson_flags.append("-Ddebug=true")
            meson_flags.append("-Doptimization=g")
        else:
            meson_flags.append("--buildtype=debugoptimized")
        if OptionKey("tests") in meson_options:
            meson_flags.append(
                self._configure_option(
                    meson_options, OptionKey("tests"), build_for_testing
                )
            )
        if OptionKey("examples") in meson_options:
            meson_flags.append(
                self._configure_option(
                    meson_options, OptionKey("examples"), build_for_testing
                )
            )
        if OptionKey("itests") in meson_options:
            meson_flags.append(
                self._configure_option(
                    meson_options, OptionKey("itests"), INTEGRATION_TEST
                )
            )
        if MESON_FLAGS.get(self.package) is not None:
            meson_flags.extend(MESON_FLAGS.get(self.package))
        return meson_flags

    def configure(self, build_for_testing):
        meson_flags = self.get_configure_flags(build_for_testing)
        try:
            check_call_cmd(
                "meson", "setup", "--reconfigure", "build", *meson_flags
            )
        except Exception:
            shutil.rmtree("build", ignore_errors=True)
            check_call_cmd("meson", "setup", "build", *meson_flags)

        self.package = Meson._project_name("build")

    def build(self):
        check_call_cmd("ninja", "-C", "build")

    def install(self):
        check_call_cmd("sudo", "-n", "--", "ninja", "-C", "build", "install")
        check_call_cmd("sudo", "-n", "--", "ldconfig")

    def test(self):
        # It is useful to check various settings of the meson.build file
        # for compatibility, such as meson_version checks.  We shouldn't
        # do this in the configure path though because it affects subprojects
        # and dependencies as well, but we only want this applied to the
        # project-under-test (otherwise an upstream dependency could fail
        # this check without our control).
        self._extra_meson_checks()

        try:
            test_args = ("--repeat", str(args.repeat), "-C", "build")
            check_call_cmd("meson", "test", "--print-errorlogs", *test_args)

        except CalledProcessError:
            raise Exception("Unit tests failed")

    def _setup_exists(self, setup):
        """
        Returns whether the meson build supports the named test setup.

        Parameter descriptions:
        setup              The setup target to check
        """
        try:
            with open(os.devnull, "w"):
                output = subprocess.check_output(
                    [
                        "meson",
                        "test",
                        "-C",
                        "build",
                        "--setup",
                        "{}:{}".format(self.package, setup),
                        "__likely_not_a_test__",
                    ],
                    stderr=subprocess.STDOUT,
                )
        except CalledProcessError as e:
            output = e.output
        output = output.decode("utf-8")
        return not re.search("Unknown test setup '[^']+'[.]", output)

    def _maybe_valgrind(self):
        """
        Potentially runs the unit tests through valgrind for the package
        via `meson test`. The package can specify custom valgrind
        configurations by utilizing add_test_setup() in a meson.build
        """
        if not is_valgrind_safe():
            sys.stderr.write("###### Skipping valgrind ######\n")
            return
        try:
            if self._setup_exists("valgrind"):
                check_call_cmd(
                    "meson",
                    "test",
                    "-t",
                    "10",
                    "-C",
                    "build",
                    "--print-errorlogs",
                    "--setup",
                    "{}:valgrind".format(self.package),
                    preexec_fn=valgrind_rlimit_nofile,
                )
            else:
                check_call_cmd(
                    "meson",
                    "test",
                    "-t",
                    "10",
                    "-C",
                    "build",
                    "--print-errorlogs",
                    "--wrapper",
                    "valgrind --error-exitcode=1",
                    preexec_fn=valgrind_rlimit_nofile,
                )
        except CalledProcessError:
            raise Exception("Valgrind tests failed")

    def analyze(self):
        self._maybe_valgrind()

        # Run clang-tidy only if the project has a configuration
        if os.path.isfile(".clang-tidy"):
            clang_env = os.environ.copy()
            clang_env["CC"] = "clang"
            clang_env["CXX"] = "clang++"
            # Clang-20 currently has some issue with libstdcpp's
            # std::forward_like which results in a bunch of compile errors.
            # Adding -fno-builtin-std-forward_like causes them to go away.
            clang_env["CXXFLAGS"] = "-fno-builtin-std-forward_like"
            clang_env["CC_LD"] = "lld"
            clang_env["CXX_LD"] = "lld"
            with TemporaryDirectory(prefix="build", dir=".") as build_dir:
                check_call_cmd("meson", "setup", build_dir, env=clang_env)
                if not os.path.isfile(".openbmc-no-clang"):
                    check_call_cmd(
                        "meson", "compile", "-C", build_dir, env=clang_env
                    )
                try:
                    check_call_cmd(
                        "ninja",
                        "-C",
                        build_dir,
                        "clang-tidy-fix",
                        env=clang_env,
                    )
                except subprocess.CalledProcessError:
                    check_call_cmd(
                        "git",
                        "-C",
                        CODE_SCAN_DIR,
                        "--no-pager",
                        "diff",
                        env=clang_env,
                    )
                    raise
        # Run the basic clang static analyzer otherwise
        else:
            check_call_cmd("ninja", "-C", "build", "scan-build")

        # Run tests through sanitizers
        # b_lundef is needed if clang++ is CXX since it resolves the
        # asan symbols at runtime only. We don't want to set it earlier
        # in the build process to ensure we don't have undefined
        # runtime code.
        if is_sanitize_safe():
            meson_flags = self.get_configure_flags(self.build_for_testing)
            meson_flags.append("-Db_sanitize=address,undefined")
            try:
                check_call_cmd(
                    "meson", "setup", "--reconfigure", "build", *meson_flags
                )
            except Exception:
                shutil.rmtree("build", ignore_errors=True)
                check_call_cmd("meson", "setup", "build", *meson_flags)
            check_call_cmd(
                "meson",
                "test",
                "-C",
                "build",
                "--print-errorlogs",
                "--logbase",
                "testlog-ubasan",
            )
            meson_flags = [
                s.replace(
                    "-Db_sanitize=address,undefined", "-Db_sanitize=none"
                )
                for s in meson_flags
            ]
            try:
                check_call_cmd(
                    "meson", "setup", "--reconfigure", "build", *meson_flags
                )
            except Exception:
                shutil.rmtree("build", ignore_errors=True)
                check_call_cmd("meson", "setup", "build", *meson_flags)
        else:
            sys.stderr.write("###### Skipping sanitizers ######\n")

        # Run coverage checks
        check_call_cmd("meson", "configure", "build", "-Db_coverage=true")
        self.test()
        # Only build coverage HTML if coverage files were produced
        for root, dirs, files in os.walk("build"):
            if any([f.endswith(".gcda") for f in files]):
                self._generate_coverage_reports()
                break
        check_call_cmd("meson", "configure", "build", "-Db_coverage=false")

    # ── Coverage report helper utilities ──────────────────────────────

    @staticmethod
    def _pct(hit, found):
        """Safe percentage: returns 0.0 when *found* is zero."""
        return (100.0 * hit / found) if found else 0.0

    @staticmethod
    def _make_metric(found, hit):
        """Return a {found, hit, percent} dict used in every coverage entry."""
        return {"found": found, "hit": hit, "percent": Meson._pct(hit, found)}

    @staticmethod
    def _compute_function_ranges(sorted_funcs):
        """Return list of (start, end) line-ranges for *sorted_funcs*."""
        ranges = []
        for idx, fn in enumerate(sorted_funcs):
            start = fn.get("line") or fn.get("__tmp_line")
            end = 10 ** 9
            if idx + 1 < len(sorted_funcs):
                nxt = sorted_funcs[idx + 1]
                end = (nxt.get("line") or nxt.get("__tmp_line")) - 1
            ranges.append((start, end))
        return ranges

    @staticmethod
    def _accumulate_in_range(mapping, start, end, keys=("found", "hit")):
        """Sum *keys* from dict-valued *mapping* for entries whose key is in [start, end]."""
        totals = {k: 0 for k in keys}
        for ln, val in mapping.items():
            if start <= ln <= end:
                if isinstance(val, dict):
                    for k in keys:
                        totals[k] += val.get(k, 0)
        return totals

    @staticmethod
    def _count_lines_in_range(line_cov, start, end):
        """Count instrumented / hit lines in [start, end]."""
        found = hit = 0
        for ln, cnt in line_cov.items():
            if start <= ln <= end:
                found += 1
                if cnt > 0:
                    hit += 1
        return found, hit

    @staticmethod
    def _build_enriched_entry(name, line, count, hit_flag,
                              line_found, line_hit, br_found, br_hit,
                              cond_found, cond_hit, blk_found=0, blk_hit=0):
        """Build the enriched function dict with all convenience keys."""
        # Fallback: mirror branch coverage when no condition data
        if cond_found == 0 and br_found > 0:
            cond_found, cond_hit = br_found, br_hit
        pct = Meson._pct
        return {
            "name": name,
            "line": line,
            "count": count,
            "hit": hit_flag,
            "lines": Meson._make_metric(line_found, line_hit),
            "branches": Meson._make_metric(br_found, br_hit),
            "conditions": Meson._make_metric(cond_found, cond_hit),
            "blocks": Meson._make_metric(blk_found, blk_hit),
            "Total Line": line_found,
            "Covered lines": line_hit,
            "Line coverage:": f"{pct(line_hit, line_found):.2f}%",
            "Total Branch": br_found,
            "Covered Branch": br_hit,
            "Branch Coverage Percentage:": f"{pct(br_hit, br_found):.2f}%",
            "Total Condition": cond_found,
            "Covered Condition": cond_hit,
            "Condition Coverage Percentage": f"{pct(cond_hit, cond_found):.2f}%",
            "Total Block": blk_found,
            "Covered Block": blk_hit,
            "blocks_percent": f"{pct(blk_hit, blk_found):.2f}%",
        }

    @staticmethod
    def _enrich_functions_from_maps(sorted_funcs, line_cov, line_br,
                                    line_cond, line_blk=None):
        """Compute per-function enriched entries from coverage maps."""
        ranges = Meson._compute_function_ranges(sorted_funcs)
        enriched = []
        for fn, (start, end) in zip(sorted_funcs, ranges):
            lf, lh = Meson._count_lines_in_range(line_cov, start, end)
            br = Meson._accumulate_in_range(line_br, start, end)
            cd = Meson._accumulate_in_range(line_cond, start, end)
            blk_found = blk_hit = 0
            if line_blk:
                blk = Meson._accumulate_in_range(line_blk, start, end)
                blk_found, blk_hit = blk["found"], blk["hit"]

            name = fn.get("name") or fn.get("__tmp_name")
            line = fn.get("line") or fn.get("__tmp_line")
            count = fn["count"]
            hit_flag = fn.get("hit", count > 0)

            enriched.append(Meson._build_enriched_entry(
                name, line, count, hit_flag,
                lf, lh, br["found"], br["hit"],
                cd["found"], cd["hit"], blk_found, blk_hit,
            ))
        return enriched

    @staticmethod
    def _write_file_json(path, rel, enriched, summary):
        """Write a per-file coverage JSON."""
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump({"file": rel, "functions": enriched, "summary": summary}, f, indent=2)

    @staticmethod
    def _write_hashed_json(coverage_dir, rel, enriched, summary):
        """Write hashed per-file JSON in json-coverage dir alongside HTML."""
        import hashlib
        sanitized = rel.replace(os.sep, ".")
        digest = hashlib.md5(rel.encode("utf-8")).hexdigest()
        hashed_name = f"index.{sanitized}.{digest}.json"
        json_dir = os.path.join(coverage_dir, "json-coverage")
        os.makedirs(json_dir, exist_ok=True)
        hashed_out = os.path.join(json_dir, hashed_name)
        with open(hashed_out, "w") as f:
            json.dump({"file": rel, "functions": enriched, "summary": summary}, f, indent=2)

    @staticmethod
    def _write_aggregate_json(agg_path, all_files_enriched,
                              total_lines, covered_lines,
                              total_branches, covered_branches,
                              extra_keys=False):
        """Write the aggregate index.functions.json."""
        pct = Meson._pct
        line_coverage = pct(covered_lines, total_lines)
        branch_coverage = pct(covered_branches, total_branches)
        data = {
            "files": all_files_enriched,
            "total_lines": total_lines,
            "covered_lines": covered_lines,
            "line_coverage": line_coverage,
            "total_branches": total_branches,
            "covered_branches": covered_branches,
            "branch_coverage": branch_coverage,
        }
        if extra_keys:
            data.update({
                "Total Line": total_lines,
                "Total Line:": total_lines,
                "Covered line": covered_lines,
                "Covered line:": covered_lines,
                "Line coverage": f"{line_coverage:.2f}%",
                "Line coverage:": f"{line_coverage:.2f}%",
                "Total Branch": total_branches,
                "Total Branch:": total_branches,
                "Covered Branch": covered_branches,
                "Covered Branch:": covered_branches,
                "Branch Coverage Percentage": f"{branch_coverage:.2f}%",
                "Branch Coverage Percentage:": f"{branch_coverage:.2f}%",
            })
        else:
            data["Line coverage %"] = f"{line_coverage:.2f}%"
            data["Branch coverage %"] = f"{branch_coverage:.2f}%"
        with open(agg_path, "w") as f:
            json.dump(data, f, indent=2)

    @staticmethod
    def _inject_conditions_into_html(coverage_dir, all_files_enriched):
        """Inject Condition coverage column into index.functions.html."""
        functions_html = os.path.join(coverage_dir, "index.functions.html")
        if not os.path.exists(functions_html):
            return

        with open(functions_html, "r", encoding="utf-8") as fh:
            html_txt = fh.read()

        # Build lookup of computed metrics by (file, line)
        func_index = {}
        for fe in all_files_enriched:
            frel = fe.get("file", "")
            for fn in fe.get("functions", []):
                func_index[(frel, int(fn.get("line", 0)))] = fn

        # Add Conditions column header if missing
        if not re.search(r'<div role="rowheader"[^>]*>\s*Conditions\s*</div>', html_txt):
            header_pat = (
                r'(?P<func><div role="rowheader"[^>]*>Function \(File:Line\)</div>)\s*'
                r'(?P<calls><div role="rowheader"[^>]*>Calls</div>)\s*'
                r'(?P<lines><div role="rowheader"[^>]*>Lines</div>)\s*'
                r'(?P<branches><div role="rowheader"(?P<br_attrs>[^>]*)>Branches</div>)\s*'
                r'(?P<blocks><div role="rowheader"[^>]*>Blocks</div>)'
            )

            def _header_inject(m):
                cond_header = f'<div role="rowheader"{m.group("br_attrs")}>Conditions</div>'
                return (
                    m.group('func') + "\n    "
                    + m.group('calls') + "\n    "
                    + m.group('lines') + "\n    "
                    + m.group('branches') + "\n    "
                    + cond_header + "\n    "
                    + m.group('blocks')
                )

            html_txt = re.sub(header_pat, _header_inject, html_txt, count=1)

        def _strip_tags(s):
            return re.sub(r"<[^>]+>", "", s or "").strip()

        def _open_tag(cell_html, default_class="color-fg-muted flex-auto min-width-0"):
            m_open = re.match(r'\s*(<div role="gridcell"[^>]*>)', cell_html or "")
            if m_open:
                return m_open.group(1)
            return f'<div role="gridcell" class="{default_class}">'

        def _get_metric_int(entry, metric, key):
            """Safely extract int from entry's nested metric dict."""
            if entry is None:
                return 0
            info = entry.get(metric, {}) or {}
            try:
                return int(info.get(key, 0) or 0)
            except Exception:
                return 0

        def _row_inject(m):
            fpath = m.group('file')
            line_no = int(m.group('line'))
            entry = func_index.get((fpath, line_no))

            calls_txt_raw = _strip_tags(m.group('calls'))
            lines_pct_text = _strip_tags(m.group('lines')) or '-%'
            branches_pct_text = _strip_tags(m.group('branches')) or '-%'
            blocks_pct_text = _strip_tags(m.group('blocks')) or '-%'

            calls = 0
            m_calls = re.search(r"called\s+(\d+)\s+time", calls_txt_raw)
            if m_calls:
                calls = int(m_calls.group(1))

            # Line coverage
            line_found = _get_metric_int(entry, 'lines', 'found')
            line_hit = _get_metric_int(entry, 'lines', 'hit')
            if entry is not None and line_found:
                line_cov_text = (
                    f"Line coverage: {Meson._pct(line_hit, line_found):.1f}%"
                    f"<br/>Total Line: {line_found}<br/>Covered lines: {line_hit}"
                )
            elif entry is not None:
                line_cov_text = f"Line coverage: {lines_pct_text}<br/>Total Line: {line_found}<br/>Covered lines: {line_hit}"
            else:
                line_cov_text = f"Line coverage: {lines_pct_text}"

            # Branch coverage
            br_found = _get_metric_int(entry, 'branches', 'found')
            br_hit = _get_metric_int(entry, 'branches', 'hit')
            if entry is not None and br_found:
                branch_cov_text = (
                    f"Branch Coverage Percentage: {Meson._pct(br_hit, br_found):.1f}%"
                    f"<br/>Total Branch: {br_found}<br/>Covered Branch: {br_hit}"
                )
            elif entry is not None:
                branch_cov_text = f"Branch Coverage Percentage: {branches_pct_text}<br/>Total Branch: {br_found}<br/>Covered Branch: {br_hit}"
            else:
                branch_cov_text = f"Branch Coverage Percentage: {branches_pct_text}"

            # Condition coverage
            cond_found = _get_metric_int(entry, 'conditions', 'found')
            cond_hit = _get_metric_int(entry, 'conditions', 'hit')
            cond_pct_text = '-%'
            if cond_found:
                cond_pct_text = f"{Meson._pct(cond_hit, cond_found):.1f}%"
            elif entry is not None:
                br_found2 = _get_metric_int(entry, 'branches', 'found')
                if br_found2 and branches_pct_text and branches_pct_text != '-%':
                    cond_pct_text = branches_pct_text
            cond_cov_text = (
                f"Condition Coverage Percentage: {cond_pct_text}"
                f"<br/>Total Condition: {cond_found}<br/>Covered Condition: {cond_hit}"
            )

            calls_cell = _open_tag(m.group('calls')) + str(calls) + "</div>"
            lines_cell = _open_tag(m.group('lines')) + line_cov_text + "</div>"
            branches_cell = _open_tag(m.group('branches')) + branch_cov_text + "</div>"
            conditions_cell = _open_tag(m.group('branches')) + cond_cov_text + "</div>"

            blk_cov_text = f"blocks_percent: {blocks_pct_text}"
            m_blk = re.search(r"([0-9.]+)%\s*\((\d+)\s*/\s*(\d+)\)", blocks_pct_text)
            if m_blk:
                blk_hit = int(m_blk.group(2))
                blk_found = int(m_blk.group(3))
                blk_cov_text = (
                    f"blocks_percent: {float(m_blk.group(1)):.1f}%"
                    f"<br/>Total Block: {blk_found}<br/>Covered Block: {blk_hit}"
                )
            blocks_cell = _open_tag(m.group('blocks')) + blk_cov_text + "</div>"

            return (
                m.group(1) + m.group('func') + "\n    "
                + calls_cell + "\n    "
                + lines_cell + "\n    "
                + branches_cell + "\n    "
                + conditions_cell + "\n    "
                + blocks_cell + "\n  </div>"
            )

        row_pat = (
            r'(<div class="Box-row[^\n>]*>\s*)'
            r'(?P<func><div role="gridcell"[^>]*>.*?\((?P<file>[^:]+):(?P<line>\d+)\).*?</div>)\s*'
            r'(?P<calls><div role="gridcell"[^>]*>.*?</div>)\s*'
            r'(?P<lines><div role="gridcell"[^>]*>.*?</div>)\s*'
            r'(?P<branches><div role="gridcell"[^>]*>.*?</div>)\s*'
            r'(?P<blocks><div role="gridcell"[^>]*>.*?</div>)\s*'
            r'</div>'
        )
        html_txt = re.sub(row_pat, _row_inject, html_txt, flags=re.S)
        with open(functions_html, "w", encoding="utf-8") as fh:
            fh.write(html_txt)

    # ── Main coverage report orchestration ────────────────────────────

    @staticmethod
    def _read_gcovr_excludes():
        """Parse exclude patterns from the project's gcovr.cfg if present.

        Returns a list of gcovr CLI args, e.g.
        ['--exclude', 'test/*', '--exclude', 'src/main.cpp'].
        Also returns the raw patterns for use with lcov --remove.
        """
        gcovr_args = []
        raw_patterns = []
        cfg_path = "gcovr.cfg"
        if not os.path.isfile(cfg_path):
            return gcovr_args, raw_patterns
        try:
            with open(cfg_path, "r") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("exclude") and "=" in line:
                        # Handle both 'exclude = pattern' and 'exclude=pattern'
                        _, _, val = line.partition("=")
                        val = val.strip()
                        if val and not val.startswith("#"):
                            # Skip exclude-unreachable-branches etc. (they
                            # are boolean flags, not path patterns)
                            key = line.split("=", 1)[0].strip()
                            if key == "exclude":
                                gcovr_args.extend(["--exclude", val])
                                raw_patterns.append(val)
        except Exception:
            pass
        return gcovr_args, raw_patterns

    def _generate_coverage_reports(self):
        """Generate all coverage report artefacts (JSON, HTML, per-file)."""
        import hashlib

        cpu_count = str(multiprocessing.cpu_count())
        gcovr_bin = shutil.which("gcovr")
        lcov_bin = shutil.which("lcov")

        cov_out_dir = os.path.join("build", "coverage")
        os.makedirs(cov_out_dir, exist_ok=True)

        # Read project-specific exclude patterns from gcovr.cfg
        gcovr_excludes, exclude_patterns = self._read_gcovr_excludes()

        # Build gcovr base command matching Meson's invocation style:
        #  - Use absolute source root with -r and build root as a
        #    positional search directory (how Meson passes them).
        #  - Always pass exclude patterns explicitly so they are
        #    applied regardless of whether gcovr auto-reads gcovr.cfg.
        source_root = os.path.abspath(".")
        build_root = os.path.abspath("build")

        gcovr_cfg_args = [
            "--exclude-directories", "subprojects",
            *gcovr_excludes,
        ]

        # ── 1. Initial gcovr JSON export ──
        if gcovr_bin is not None:
            try:
                check_call_cmd(
                    "gcovr", "-r", source_root, build_root,
                    "-j", cpu_count,
                    *gcovr_cfg_args,
                    "--json", os.path.join(cov_out_dir, "coverage.json"),
                    "--json-pretty", "--print-summary",
                )
            except subprocess.CalledProcessError:
                print("gcovr JSON export failed")
        else:
            print("gcovr not found; skipping JSON coverage export")

        # ── 2. Meson HTML coverage ──
        check_call_cmd("ninja", "-C", "build", "coverage-html")

        # Locate directory containing index.html
        coverage_dir = None
        for d in [os.path.join("build", "meson-logs", "coverage"),
                  os.path.join("build", "meson-logs", "coveragereport")]:
            if os.path.exists(os.path.join(d, "index.html")):
                coverage_dir = d
                break
        if coverage_dir is None:
            coverage_dir = os.path.join("build", "meson-logs", "coverage")
            os.makedirs(coverage_dir, exist_ok=True)

        json_root_dir = os.path.join(coverage_dir, "json-coverage")
        os.makedirs(json_root_dir, exist_ok=True)

        # ── 3. Detect gcovr --conditions support ──
        supports_conditions = False
        if gcovr_bin is not None:
            try:
                help_out = subprocess.run(
                    ["gcovr", "--help"],
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, check=False,
                )
                supports_conditions = "--conditions" in (help_out.stdout or "")
            except Exception:
                pass

        # Shared gcovr base args
        gcovr_base = [
            "gcovr", "-r", source_root, build_root,
            "-j", cpu_count,
            *gcovr_cfg_args,
        ]

        def _maybe_add_conditions(cmd):
            if supports_conditions:
                cmd.insert(-1, "--conditions")

        # ── 4. Regenerate HTML with branch/condition metrics ──
        if gcovr_bin is not None:
            try:
                html_cmd = [
                    "gcovr", "-r", source_root, build_root,
                    "-j", cpu_count,
                    *gcovr_cfg_args,
                    "--html", "--html-details",
                    "--print-summary",
                    "-o", os.path.join(coverage_dir, "index.html"),
                ]
                if supports_conditions:
                    html_cmd.insert(-2, "--conditions")
                else:
                    print("gcovr without --conditions; generating HTML without condition metrics")
                check_call_cmd(*html_cmd)
            except Exception:
                print("Skipping HTML regeneration with condition metrics due to unexpected error")
        else:
            print("gcovr not found; using Meson-generated HTML without condition metrics")

        # ── 5. JSON summary (index.json) ──
        try:
            json_summary_cmd = gcovr_base + [
                "--json-summary", os.path.join(json_root_dir, "index.json"),
            ]
            _maybe_add_conditions(json_summary_cmd)
            check_call_cmd(*json_summary_cmd)
        except CalledProcessError:
            print("gcovr JSON summary export failed")

        # ── 6. Detailed JSON (index.function.json) ──
        try:
            json_detail_cmd = gcovr_base + [
                "--json", os.path.join(json_root_dir, "index.function.json"),
            ]
            _maybe_add_conditions(json_detail_cmd)
            check_call_cmd(*json_detail_cmd)
        except CalledProcessError:
            print("gcovr detailed JSON export failed")

        # ── 7. Per-file function-wise JSON ──
        try:
            if lcov_bin is not None:
                self._generate_lcov_function_json(
                    cov_out_dir, coverage_dir, json_root_dir,
                    exclude_patterns)
            else:
                self._generate_gcovr_fallback_json(
                    coverage_dir, json_root_dir)
        except Exception:
            print("Skipping function-wise JSON export due to unexpected error")

    # ── lcov-based per-file function JSON ─────────────────────────────

    def _generate_lcov_function_json(self, cov_out_dir, coverage_dir,
                                     json_root_dir, exclude_patterns=None):
        """Parse lcov.info and produce per-file + aggregate function JSON."""
        raw_info = os.path.join(cov_out_dir, "lcov_raw.info")
        info = os.path.join(cov_out_dir, "lcov.info")

        check_call_cmd(
            "lcov", "--capture", "--rc", "lcov_branch_coverage=1",
            "--directory", "build", "--output-file", raw_info,
        )
        # Build lcov --remove patterns: always exclude subprojects and
        # system paths, plus any project-specific patterns from gcovr.cfg
        lcov_remove_patterns = ["*/subprojects/*", "/usr/*"]
        if exclude_patterns:
            for pat in exclude_patterns:
                # Convert gcovr glob patterns to lcov-style patterns:
                # gcovr uses paths relative to root (e.g. 'test/*'),
                # lcov expects shell-style wildcards (e.g. '*/test/*')
                if not pat.startswith("*"):
                    lcov_remove_patterns.append("*/" + pat)
                else:
                    lcov_remove_patterns.append(pat)
        try:
            check_call_cmd(
                "lcov", "--remove", raw_info,
                *lcov_remove_patterns, "--output-file", info,
            )
        except subprocess.CalledProcessError:
            shutil.copyfile(raw_info, info)

        func_json_root = os.path.join(cov_out_dir, "functions-json")
        os.makedirs(func_json_root, exist_ok=True)

        all_files_enriched = []

        def _flush_file_record(sf, fn_map, fn_counts, line_cov, line_br, line_cond):
            rel = os.path.relpath(sf, ".")
            hit = 0
            functions = []
            for name, line_no in fn_map.items():
                count = int(float(fn_counts.get(name, 0)))
                if count > 0:
                    hit += 1
                functions.append({
                    "__tmp_name": name, "__tmp_line": int(line_no),
                    "count": count, "hit": count > 0,
                })
            summary = self._make_metric(len(fn_map), hit)

            sorted_funcs = sorted(functions, key=lambda x: (x["__tmp_line"], x["__tmp_name"]))
            enriched = self._enrich_functions_from_maps(
                sorted_funcs, line_cov, line_br, line_cond)

            out_path = os.path.join(func_json_root, rel + ".json")
            self._write_file_json(out_path, rel, enriched, summary)

            try:
                self._write_hashed_json(coverage_dir, rel, enriched, summary)
            except Exception:
                pass

            try:
                all_files_enriched.append({
                    "file": rel, "functions": enriched, "summary": summary,
                    "_lines_found": len(line_cov),
                    "_lines_hit": sum(1 for v in line_cov.values() if v > 0),
                    "_branches_found": sum(br.get("found", 0) for br in line_br.values()),
                    "_branches_hit": sum(br.get("hit", 0) for br in line_br.values()),
                })
            except Exception:
                pass

        # Parse lcov.info
        current_file = None
        fn_map = fn_counts = line_cov = line_br = line_cond = None

        def _reset_state():
            return {}, {}, {}, {}, {}

        fn_map, fn_counts, line_cov, line_br, line_cond = _reset_state()

        with open(info, "r") as f:
            for line in f:
                s = line.strip()
                if s.startswith("SF:"):
                    if current_file is not None:
                        _flush_file_record(current_file, fn_map, fn_counts, line_cov, line_br, line_cond)
                    current_file = s[3:]
                    fn_map, fn_counts, line_cov, line_br, line_cond = _reset_state()
                elif s.startswith("FN:"):
                    try:
                        ln, name = s[3:].split(",", 1)
                        fn_map[name] = int(ln)
                    except Exception:
                        pass
                elif s.startswith("FNDA:"):
                    try:
                        cnt, name = s[5:].split(",", 1)
                        fn_counts[name] = int(float(cnt))
                    except Exception:
                        pass
                elif s.startswith("DA:"):
                    try:
                        parts = s[3:].split(",")
                        line_cov[int(parts[0])] = int(float(parts[1]))
                    except Exception:
                        pass
                elif s.startswith("BRDA:"):
                    try:
                        parts = s[5:].split(",")
                        ln = int(parts[0])
                        taken = parts[3]
                        if ln not in line_br:
                            line_br[ln] = {"found": 0, "hit": 0}
                        line_br[ln]["found"] += 1
                        if taken != "-" and int(float(taken)) > 0:
                            line_br[ln]["hit"] += 1
                    except Exception:
                        pass
                elif s == "end_of_record":
                    if current_file is not None:
                        _flush_file_record(current_file, fn_map, fn_counts, line_cov, line_br, line_cond)
                        current_file = None
                        fn_map, fn_counts, line_cov, line_br, line_cond = _reset_state()
        if current_file is not None:
            _flush_file_record(current_file, fn_map, fn_counts, line_cov, line_br, line_cond)

        # Write aggregate
        try:
            total_lines = covered_lines = total_branches = covered_branches = 0
            for entry in all_files_enriched:
                total_lines += entry.pop("_lines_found", 0)
                covered_lines += entry.pop("_lines_hit", 0)
                total_branches += entry.pop("_branches_found", 0)
                covered_branches += entry.pop("_branches_hit", 0)

            agg_path = os.path.join(json_root_dir, "index.functions.json")
            self._write_aggregate_json(
                agg_path, all_files_enriched,
                total_lines, covered_lines, total_branches, covered_branches)

            try:
                self._inject_conditions_into_html(coverage_dir, all_files_enriched)
            except Exception:
                print("Failed to inject Condition coverage into index.functions.html")
        except Exception:
            print("Failed to write aggregate index.functions.json (lcov path)")

    # ── gcovr fallback per-file function JSON ─────────────────────────

    def _generate_gcovr_fallback_json(self, coverage_dir, json_root_dir):
        """Derive per-file function JSONs from gcovr detailed JSON."""
        import hashlib

        detailed_json = os.path.join(json_root_dir, "index.function.json")
        if not os.path.exists(detailed_json):
            print("gcovr detailed JSON not found for fallback export")
            return

        try:
            with open(detailed_json, "r") as dj:
                report = json.load(dj)
        except Exception:
            print("Fallback per-file JSON export from gcovr failed")
            return

        all_files_enriched = []
        for file_data in report.get("files", []):
            rel = file_data.get("file") or file_data.get("filename")
            if not rel:
                continue

            line_cov, line_br, line_cond, line_blk = {}, {}, {}, {}

            for ln in file_data.get("lines", []):
                ln_no = ln.get("line_number") or ln.get("line")
                if ln_no is None:
                    continue
                try:
                    line_cov[int(ln_no)] = int(ln.get("count", 0))
                except Exception:
                    pass

                # Branch details
                brs = ln.get("branches") or []
                if isinstance(brs, list) and brs:
                    found = len(brs)
                    hit = sum(1 for b in brs if (b.get("count", 0) or 0) > 0)
                    line_br[int(ln_no)] = {"found": found, "hit": hit}

                # Condition coverage extraction
                cond_found = cond_hit = 0
                conds = ln.get("conditions")
                if isinstance(conds, list) and conds:
                    for c in conds:
                        nested = c.get("conditions")
                        if isinstance(nested, list) and nested:
                            cond_found += len(nested)
                            for nc in nested:
                                cov = nc.get("coverage")
                                cnt2 = nc.get("count", nc.get("hits", 0))
                                if (cov is not None and float(cov) > 0) or (cnt2 and int(cnt2) > 0):
                                    cond_hit += 1
                        else:
                            cov = c.get("coverage")
                            cnt2 = c.get("count", c.get("hits", 0))
                            cond_found += 1
                            if (cov is not None and float(cov) > 0) or (cnt2 and int(cnt2) > 0):
                                cond_hit += 1
                line_cond[int(ln_no)] = {"found": cond_found, "hit": cond_hit}

                # Block coverage
                try:
                    blks = ln.get("blocks")
                    blk_found = blk_hit = 0
                    if isinstance(blks, list) and blks:
                        blk_found = len(blks)
                        blk_hit = sum(1 for b in blks if (b.get("count", 0) or 0) > 0)
                    line_blk[int(ln_no)] = {"found": blk_found, "hit": blk_hit}
                except Exception:
                    line_blk[int(ln_no)] = {"found": 0, "hit": 0}

            # Build function list
            fun_list = []
            for fn in file_data.get("functions", []):
                name = fn.get("name")
                start = fn.get("start_line") or fn.get("lineno") or fn.get("line")
                cnt = fn.get("execution_count") or fn.get("count") or 0
                if name is None or start is None:
                    continue
                fun_list.append({"name": name, "line": int(start), "count": int(cnt)})
            fun_list.sort(key=lambda x: (x["line"], x["name"]))

            enriched = self._enrich_functions_from_maps(
                fun_list, line_cov, line_br, line_cond, line_blk)

            hit_funcs = sum(1 for e in enriched if e["hit"])
            summary = self._make_metric(len(fun_list), hit_funcs)

            # Write per-file JSON
            out_plain = os.path.join("build", "coverage", "functions-json", rel + ".json")
            self._write_file_json(out_plain, rel, enriched, summary)
            self._write_hashed_json(coverage_dir, rel, enriched, summary)

            all_files_enriched.append({
                "file": rel, "functions": enriched, "summary": summary,
            })

        # Write aggregate
        try:
            total_lines = covered_lines = total_branches = covered_branches = 0
            for entry in all_files_enriched:
                for fn in entry.get("functions", []):
                    total_lines += fn.get("lines", {}).get("found", 0)
                    covered_lines += fn.get("lines", {}).get("hit", 0)
                    total_branches += fn.get("branches", {}).get("found", 0)
                    covered_branches += fn.get("branches", {}).get("hit", 0)

            agg_path = os.path.join(json_root_dir, "index.functions.json")
            self._write_aggregate_json(
                agg_path, all_files_enriched,
                total_lines, covered_lines, total_branches, covered_branches,
                extra_keys=True)

            try:
                self._inject_conditions_into_html(coverage_dir, all_files_enriched)
            except Exception:
                print("Failed to inject Condition coverage into index.functions.html")
        except Exception:
            print("Failed to write aggregate index.functions.json (gcovr fallback)")

    def _extra_meson_checks(self):
        with open(os.path.join(self.path, "meson.build"), "rt") as f:
            build_contents = f.read()

        # Find project's specified meson_version.
        meson_version = None
        pattern = r"meson_version:[^']*'([^']*)'"
        for match in re.finditer(pattern, build_contents):
            group = match.group(1)
            meson_version = group

        # C++20 requires at least Meson 0.57 but Meson itself doesn't
        # identify this.  Add to our unit-test checks so that we don't
        # get a meson.build missing this.
        pattern = r"'cpp_std=c\+\+20'"
        for match in re.finditer(pattern, build_contents):
            if not meson_version or not meson_version_compare(
                meson_version, ">=0.57"
            ):
                raise Exception(
                    "C++20 support requires specifying in meson.build: "
                    + "meson_version: '>=0.57'"
                )

        # C++23 requires at least Meson 1.1.1 but Meson itself doesn't
        # identify this.  Add to our unit-test checks so that we don't
        # get a meson.build missing this.
        pattern = r"'cpp_std=c\+\+23'"
        for match in re.finditer(pattern, build_contents):
            if not meson_version or not meson_version_compare(
                meson_version, ">=1.1.1"
            ):
                raise Exception(
                    "C++23 support requires specifying in meson.build: "
                    + "meson_version: '>=1.1.1'"
                )

        if "get_variable(" in build_contents:
            if not meson_version or not meson_version_compare(
                meson_version, ">=0.58"
            ):
                raise Exception(
                    "dep.get_variable() with positional argument requires "
                    + "meson_version: '>=0.58'"
                )

        if "relative_to(" in build_contents:
            if not meson_version or not meson_version_compare(
                meson_version, ">=1.3.0"
            ):
                raise Exception(
                    "fs.relative_to() requires meson_version: '>=1.3.0'"
                )


class Package(object):
    def __init__(self, name=None, path=None):
        self.supported = [Meson, Autotools, CMake]
        self.name = name
        self.path = path
        self.test_only = False

    def build_systems(self):
        instances = (system(self.name, self.path) for system in self.supported)
        return (instance for instance in instances if instance.probe())

    def build_system(self, preferred=None):
        systems = list(self.build_systems())

        if not systems:
            return None

        if preferred:
            return {type(system): system for system in systems}[preferred]

        return next(iter(systems))

    def install(self, system=None):
        if not system:
            system = self.build_system()

        system.configure(False)
        system.build()
        system.install()

    def _test_one(self, system):
        system.configure(True)
        system.build()
        system.install()
        system.test()
        if not TEST_ONLY:
            system.analyze()

    def test(self):
        for system in self.build_systems():
            self._test_one(system)


def find_file(filename, basedir):
    """
    Finds all occurrences of a file (or list of files) in the base
    directory and passes them back with their relative paths.

    Parameter descriptions:
    filename              The name of the file (or list of files) to
                          find
    basedir               The base directory search in
    """

    if not isinstance(filename, list):
        filename = [filename]

    filepaths = []
    for root, dirs, files in os.walk(basedir):
        if os.path.split(root)[-1] == "subprojects":
            for f in files:
                subproject = ".".join(f.split(".")[0:-1])
                if f.endswith(".wrap") and subproject in dirs:
                    # don't find files in meson subprojects with wraps
                    dirs.remove(subproject)
        for f in filename:
            if f in files:
                filepaths.append(os.path.join(root, f))
    return filepaths


if __name__ == "__main__":
    # CONFIGURE_FLAGS = [GIT REPO]:[CONFIGURE FLAGS]
    CONFIGURE_FLAGS = {
        "phosphor-logging": [
            "--enable-metadata-processing",
            "--enable-openpower-pel-extension",
            "YAML_DIR=/usr/local/share/phosphor-dbus-yaml/yaml",
        ]
    }

    # MESON_FLAGS = [GIT REPO]:[MESON FLAGS]
    MESON_FLAGS = {
        "phosphor-dbus-interfaces": [
            "-Ddata_com_ibm=true",
            "-Ddata_org_open_power=true",
        ],
        "phosphor-logging": ["-Dopenpower-pel-extension=enabled"],
    }

    # DEPENDENCIES = [MACRO]:[library/header]:[GIT REPO]
    DEPENDENCIES = {
        "AC_CHECK_LIB": {"mapper": "phosphor-objmgr"},
        "AC_CHECK_HEADER": {
            "host-ipmid": "phosphor-host-ipmid",
            "blobs-ipmid": "phosphor-ipmi-blobs",
            "sdbusplus": "sdbusplus",
            "sdeventplus": "sdeventplus",
            "stdplus": "stdplus",
            "gpioplus": "gpioplus",
            "phosphor-logging/log.hpp": "phosphor-logging",
        },
        "AC_PATH_PROG": {"sdbus++": "sdbusplus"},
        "PKG_CHECK_MODULES": {
            "phosphor-dbus-interfaces": "phosphor-dbus-interfaces",
            "libipmid": "phosphor-host-ipmid",
            "libipmid-host": "phosphor-host-ipmid",
            "sdbusplus": "sdbusplus",
            "sdeventplus": "sdeventplus",
            "stdplus": "stdplus",
            "gpioplus": "gpioplus",
            "phosphor-logging": "phosphor-logging",
            "phosphor-snmp": "phosphor-snmp",
            "ipmiblob": "ipmi-blob-tool",
            "hei": "openpower-libhei",
            "phosphor-ipmi-blobs": "phosphor-ipmi-blobs",
            "libcr51sign": "google-misc",
        },
    }

    # Offset into array of macro parameters MACRO(0, 1, ...N)
    DEPENDENCIES_OFFSET = {
        "AC_CHECK_LIB": 0,
        "AC_CHECK_HEADER": 0,
        "AC_PATH_PROG": 1,
        "PKG_CHECK_MODULES": 1,
    }

    # DEPENDENCIES_REGEX = [GIT REPO]:[REGEX STRING]
    DEPENDENCIES_REGEX = {"phosphor-logging": r"\S+-dbus-interfaces$"}

    # Set command line arguments
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-w",
        "--workspace",
        dest="WORKSPACE",
        required=True,
        help="Workspace directory location(i.e. /home)",
    )
    parser.add_argument(
        "-p",
        "--package",
        dest="PACKAGE",
        required=True,
        help="OpenBMC package to be unit tested",
    )
    parser.add_argument(
        "-t",
        "--test-only",
        dest="TEST_ONLY",
        action="store_true",
        required=False,
        default=False,
        help="Only run test cases, no other validation",
    )
    arg_inttests = parser.add_mutually_exclusive_group()
    arg_inttests.add_argument(
        "--integration-tests",
        dest="INTEGRATION_TEST",
        action="store_true",
        required=False,
        default=True,
        help="Enable integration tests [default].",
    )
    arg_inttests.add_argument(
        "--no-integration-tests",
        dest="INTEGRATION_TEST",
        action="store_false",
        required=False,
        help="Disable integration tests.",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Print additional package status messages",
    )
    parser.add_argument(
        "-r", "--repeat", help="Repeat tests N times", type=int, default=1
    )
    parser.add_argument(
        "-b",
        "--branch",
        dest="BRANCH",
        required=False,
        help="Branch to target for dependent repositories",
        default="master",
    )
    parser.add_argument(
        "-n",
        "--noformat",
        dest="FORMAT",
        action="store_false",
        required=False,
        help="Whether or not to run format code",
    )
    args = parser.parse_args(sys.argv[1:])
    WORKSPACE = args.WORKSPACE
    UNIT_TEST_PKG = args.PACKAGE
    TEST_ONLY = args.TEST_ONLY
    INTEGRATION_TEST = args.INTEGRATION_TEST
    BRANCH = args.BRANCH
    FORMAT_CODE = args.FORMAT
    if args.verbose:

        def printline(*line):
            for arg in line:
                print(arg, end=" ")
            print()

    else:

        def printline(*line):
            pass

    CODE_SCAN_DIR = os.path.join(WORKSPACE, UNIT_TEST_PKG)

    # Run format-code.sh, which will in turn call any repo-level formatters.
    if FORMAT_CODE:
        check_call_cmd(
            os.path.join(
                WORKSPACE, "openbmc-build-scripts", "scripts", "format-code.sh"
            ),
            CODE_SCAN_DIR,
        )

        # Check to see if any files changed
        check_call_cmd(
            "git", "-C", CODE_SCAN_DIR, "--no-pager", "diff", "--exit-code"
        )

    # Check if this repo has a supported make infrastructure
    pkg = Package(UNIT_TEST_PKG, CODE_SCAN_DIR)
    if not pkg.build_system():
        print("No valid build system, exit")
        sys.exit(0)

    prev_umask = os.umask(000)

    # Determine dependencies and add them
    dep_added = dict()
    dep_added[UNIT_TEST_PKG] = False

    # Create dependency tree
    dep_tree = DepTree(UNIT_TEST_PKG)
    build_dep_tree(UNIT_TEST_PKG, CODE_SCAN_DIR, dep_added, dep_tree, BRANCH)

    # Reorder Dependency Tree
    for pkg_name, regex_str in DEPENDENCIES_REGEX.items():
        dep_tree.ReorderDeps(pkg_name, regex_str)
    if args.verbose:
        dep_tree.PrintTree()

    install_list = dep_tree.GetInstallList()

    # We don't want to treat our package as a dependency
    install_list.remove(UNIT_TEST_PKG)

    # Install reordered dependencies
    for dep in install_list:
        build_and_install(dep, False)

    # Run package unit tests
    build_and_install(UNIT_TEST_PKG, True)

    os.umask(prev_umask)

    # Run any custom CI scripts the repo has, of which there can be
    # multiple of and anywhere in the repository.
    ci_scripts = find_file(["run-ci.sh", "run-ci"], CODE_SCAN_DIR)
    if ci_scripts:
        os.chdir(CODE_SCAN_DIR)
        for ci_script in ci_scripts:
            check_call_cmd(ci_script)
