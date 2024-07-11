#!/usr/bin/env python3
###############################################################################
#
# This script is for starting QEMU against the input build and running the
# robot CI test suite against it.(ROBOT CI TEST CURRENTLY WIP)
#
###############################################################################
#
# Parameters used by the script:
#  UPSTREAM_WORKSPACE = The directory from which the QEMU components are being
#                       imported from. Generally, this is the build directory
#                       that is generated by the OpenBMC build-setup.sh script
#                       when run with "target=qemuarm".
#                       Example: /home/builder/workspace/openbmc-build/build.
#
# Optional Variables:
#
#  WORKSPACE          = Path of the workspace directory where some intermediate
#                       files will be saved to.
#  DOCKER_IMG_NAME    = Defaults to openbmc/ubuntu-robot-qemu, the name the
#                       Docker image will be tagged with when built.
#                       Added a "pull" semantic to actively pull the image.
#                       "pull container:latest"
#  OBMC_QEMU_BUILD_DIR     = Defaults to /tmp/openbmc/build, the path to the
#                       directory where the UPSTREAM_WORKSPACE build files will
#                       be mounted to. Since the build containers have been
#                       changed to use /tmp as the parent directory for their
#                       builds, move the mounting location to be the same to
#                       resolve issues with file links or referrals to exact
#                       paths in the original build directory. If the build
#                       directory was changed in the build-setup.sh run, this
#                       variable should also be changed. Otherwise, the default
#                       should be used.
#  LAUNCH             = Used to determine how to launch the qemu robot test
#                       containers. The options are "local", and "k8s". It will
#                       default to local which will launch a single container
#                       to do the runs. If specified k8s will launch a group of
#                       containers into a kubernetes cluster using the helper
#                       script.
#  QEMU_BIN           = Location of qemu-system-arm binary to use when starting
#                       QEMU relative to upstream workspace.  Default is
#                       ./tmp/sysroots/${QEMU_ARCH}/usr/bin/qemu-system-arm
#                       which is the default location when doing a bitbake
#                       of obmc-phosphor-image. If you don't find the sysroots
#                       folder, run `bitbake build-sysroots`.
#
#  MACHINE            = Machine to run test against. The options are "witherspoon",
#                       "palmetto", "romulus", or undefined (default).  Default
#                       will use the versatilepb model.
#
#  DEFAULT_IMAGE_LOC  = The image location of the target MACHINE. Default to
#                       "./tmp/deploy/images/"
#
#  OBMC_QEMU_DOCKER   = (testing) Use a persistent Docker container if runtime
#                       verified
#  KEEP_QEMU_PERSISTENT = (testing) if set, it will not attempt to stop the
#                       qemu container so that it is left persistent for
#                       testing.
#  INTERACT           = (testing) if set, it will allow for interactive
#                       session in the qemu container to bypass pexpect issues.
#  HOSTBIN            = (testing) use --network=host for Robot container and
#                       qmeu (container or process)
#  HOSTBINPERSIST     = (testing) if set then the qemu process manually run
#                       and is used without starting it within a container.
#
###############################################################################

import inspect
import json
import os
import subprocess
import sys
from datetime import datetime

import pexpect
import sh


def docker_inspect_check(container, exit_on_fail=False):
    """docker inspect and return JSON contents"""
    # Sanity check:
    ret = subprocess.run(
        [DOCKER, "inspect", container], capture_output=True, check=False
    )

    if ret.returncode == 0:
        print("docker_inspect_check: succeeded " + container)
        return ret.stdout.decode("utf-8").rstrip()
    else:
        if exit_on_fail:
            sys.exit("docker_inspect_check: failed " + container)
        return None


# originally from
#  https://stackoverflow.com/questions/3718657/how-do-you-properly-determine-the-current-script-directory
def get_script_dir(follow_symlinks=True):
    """Get the script working directory"""
    if getattr(sys, "frozen", False):
        path = os.path.abspath(sys.executable)
    else:
        path = inspect.getabsfile(get_script_dir)
    if follow_symlinks:
        path = os.path.realpath(path)
    return os.path.dirname(path)


# Recipe from https://code.activestate.com/recipes/577058/
#
# "question" is a string that is presented to the user.
# "default" is the presumed answer if the user just hits <Enter>.
#        It must be "yes" (the default), "no" or None (meaning
#        an answer is required of the user).
#
# The "answer" return value is True for "yes" or False for "no".
def query_yes_no(question, default="yes"):
    """Ask a yes/no question via raw_input() and return the answer"""

    valid = {"yes": True, "y": True, "ye": True, "no": False, "n": False}
    if default is None:
        prompt = " [y/n] "
    elif default == "yes":
        prompt = " [Y/n] "
    elif default == "no":
        prompt = " [y/N] "
    else:
        raise ValueError(f"invalid default answer: '{default}'")

    while True:
        sys.stdout.write(question + prompt)
        choice = input().lower()
        if default is not None and choice == "":
            ret = valid[default]
            break
        if choice in valid:
            ret = valid[choice]
            break
        sys.stdout.write(
            "Please respond with 'yes' or 'no' (or 'y' or 'n').\n"
        )

    return ret


DEFAULT_MACHINE = "versatilepb"

HOME = str(os.environ["HOME"])

RANDOM = "blah"
WORKSPACE = os.environ.get("WORKSPACE", f"{HOME}/{RANDOM}{RANDOM}")  # TODO


def env_proxy_build_args(env):
    ret = []

    if env:
        prox = env.split()

        i = len(prox)
        while i > 0:
            ret += ["--env"]
            i -= 1
            print(f"i={i}")

            ret += [prox[i]]

    return ret


proxy_args = env_proxy_build_args(os.environ.get("PROXY", []))


DOCKER = os.environ.get("DOCKER", "docker")
print(f"DOCKER={DOCKER}")

DOCKER_IMG_NAME = os.environ.get(
    "DOCKER_IMG_NAME", "openbmc/ubuntu-robot-qemu"
)
print(f"DOCKER_IMG_NAME={DOCKER_IMG_NAME}")

OBMC_QEMU_BUILD_DIR = os.environ.get(
    "OBMC_QEMU_BUILD_DIR", "/tmp/openbmc/build"
)

UPSTREAM_WORKSPACE = os.environ.get("UPSTREAM_WORKSPACE", None)
if not UPSTREAM_WORKSPACE:
    sys.exit("env var UPSTREAM_WORKSPACE is required and not set")

LAUNCH = os.environ.get("LAUNCH", "local")
print(f"LAUNCH={LAUNCH}")

MACHINE = os.environ.get("MACHINE", DEFAULT_MACHINE)
print(f"MACHINE = {MACHINE}")

KEEP_QEMU_PERSISTENT = os.environ.get("KEEP_QEMU_PERSISTENT", False)
print(f"KEEP_QEMU_PERSISTENT = {KEEP_QEMU_PERSISTENT}")

HOSTNETWORKING = os.environ.get("HOSTNETWORKING", False)
print(f"HOSTNETWORKING = {HOSTNETWORKING}")

HOSTBINPERSIST = os.environ.get("HOSTBINPERSIST", False)
print(f"HOSTBINPERSIST = {HOSTBINPERSIST}")

HOSTBIN = os.environ.get("HOSTBIN", False)
print(f"HOSTBIN = {HOSTBIN}")

OBMC_QEMU_DOCKER = os.environ.get("OBMC_QEMU_DOCKER", False)
if OBMC_QEMU_DOCKER:
    if not docker_inspect_check(OBMC_QEMU_DOCKER, exit_on_fail=False):
        OBMC_QEMU_DOCKER = None  # failed the check, clobber invalid value

print(f"OBMC_QEMU_DOCKER = {OBMC_QEMU_DOCKER}")

DEFAULT_IMAGE_LOC = os.environ.get("DEFAULT_IMAGE_LOC", "/tmp/deploy/images/")

INTERACT = os.environ.get("INTERACT", False)

# Determine the prefix of the Dockerfile's base image and the QEMU_ARCH
# variable
ARCH = os.uname().machine
if ARCH == "ppc64le":
    QEMU_ARCH = "ppc64le-linux"
elif ARCH == "x86_64":
    QEMU_ARCH = "x86_64-linux"
elif ARCH == "aarch64":
    QEMU_ARCH = "arm64-linux"
else:
    sys.exit(
        f"Unsupported system architecture({ARCH})" " found for docker image"
    )

# Set the location of the qemu binary relative to UPSTREAM_WORKSPACE
QEMU_BIN = os.environ.get(
    "QEMU_BIN", f"./tmp/sysroots/{QEMU_ARCH}/usr/bin/qemu-system-arm"
)

# We can use default ports because we're going to have the 2
# docker instances talk over their private network
SSH_PORT = os.environ.get("SSH_PORT", "22")
HTTPS_PORT = os.environ.get("HTTPS_PORT", "443")

# Get the base directory of the openbmc-build-scripts repo so we can return
DIR = get_script_dir()

# The automated test suite needs a real machine type so
# if we're using versatilepb for our qemu start parameter
# then we need to just let our run-robot use the default
if MACHINE == DEFAULT_MACHINE:
    MACHINE_QEMU = ""
else:
    MACHINE_QEMU = MACHINE


# Create the base Docker image for QEMU and Robot
def docker_build_image():
    print("docker_build_image:")
    try:
        ret = subprocess.run(
            [DIR + "/scripts/build-qemu-robot-docker.sh", DOCKER_IMG_NAME],
            check=True,
        )
        if ret.returncode != 0:
            sys.exit("build-qemu-robot-docker/ failed")
    except subprocess.CalledProcessError as e:
        print(e)
        sys.exit("Failed to create docker")


# Build or pull the Docker image
def docker_build_pull_image(image):
    # check to see if "image" has arguments
    args = str.split(image)

    # default pull from docker.io repo
    build = False

    # Parse the env variable for "pull" if so then pull the image using
    # Docker
    if len(args) > 1:
        if args[0] == "pull":
            image = args[1]
            exe = [DOCKER, "pull", image]
            try:
                ret = subprocess.run(
                    exe,
                    check=True,
                )
                if ret.returncode != 0:
                    sys.exit("build-qemu-robot-docker/ failed")
            except subprocess.CalledProcessError as e:
                print(e)
                sys.exit("Failed to pull docker")

            print("docker_pull_qemu: pull case")
            ret = args[1]  # Overwrite it
        else:
            build = True
    else:
        build = True

    # Build the Docker image
    if build:
        docker_build_image()

    return ret


# podman work around
detach_args = []
detach_args = ["--detach-keys=ctrl-p,ctrl-p"]


def pexpect_child_interact(child, msg):
    """docker attach ARGS for an interactive session"""
    print(f"pexpect_child_interact: {msg}")
    ret = subprocess.run(
        [DOCKER, "attach"] + detach_args + [OBMC_QEMU_DOCKER], check=False
    )
    if ret.returncode != 0:
        # returncode = 1 is ok
        if ret.returncode != 1:
            print(ret)
            sys.exit("docker-attach: failed {m}")

    print("docker-attach: succeeded {m}")


# TODO
def docker_kill(container):
    """docker kill ARGS for cleanup"""
    try:
        subprocess.run([DOCKER, "stop", container], check=True)
        subprocess.run([DOCKER, "rm", container], check=True)
    except subprocess.CalledProcessError as e:
        print(e)


def docker_stop(container, m):
    """docker stop"""
    try:
        subprocess.run([DOCKER, "stop", container], check=True)
    except subprocess.CalledProcessError as e:
        print(f"docker_stop: {m}")
        print(e)


def docker_run(args, m):
    """docker run"""
    #    print(args)
    try:
        print(f"docker_run: {args}")
        ret = subprocess.run(
            [DOCKER, "run"] + args, capture_output=True, check=True
        )
        print(f"docker-run: ret={ret}")
    except subprocess.CalledProcessError as e:
        print(e)
        sys.exit(f"docker-run failed {m}")

    c = ret.stdout.decode("utf-8").rstrip()
    print(f"docker-run: {m}={c}")
    return c


def pexpect_child_from_container(container):
    try:
        child = pexpect.spawn(
            DOCKER,
            ["attach"] + detach_args + [container],
            timeout=None,
            encoding="utf-8",
        )

        child.logfile = sys.stdout
    except Exception as e:  # pylint: disable=broad-except
        print("pexpect_child_from_container: ")
        print(e)
        sys.exit("send/expect failed")

    return child, None


def pexpect_child_send_expect(child):
    """send/expect prompt match"""
    print("pexpect_child_send_expect:")

    def match_token(match, mesg):
        """Returning 0 is success"""
        if match == 0:
            print(f"got {mesg}")
        elif match == 1:
            sys.exit("got EOF expectedly")
        elif match == 2:
            print("got pexpect TIMEOUT")
        elif match == 3:
            print("got BMC TIMEOUT")
        else:
            print("uncaught index")
            sys.exit("uncaught send/expect index")

        return match

    def mlist(token):
        # catch "Login timed out after 60 seconds."
        return [token] + [pexpect.EOF, pexpect.TIMEOUT, r"\wogin\stimed"]

    child.sendline("")

    try:
        while True:
            if match_token(
                child.expect(mlist(r".* login: "), timeout=1000), "login"
            ):
                continue

            child.sendline("root")

            if match_token(
                child.expect(mlist(r"Password:"), timeout=1000), "password"
            ):
                continue

            child.sendline("0penBmc")

            # catch "root@yosemite4:~#"
            if match_token(
                child.expect(mlist(r".*root@.*:~#.*"), timeout=1000), "prompt"
            ):
                continue
            else:
                break

    except Exception as e:  # pylint: disable=broad-except
        print("pexpect_child_send_expect: match failure")
        print(e)
        sys.exit("send/expect failed")

    child.delaybeforesend = 0.5
    child.logfile = sys.stdout
    child.sendline("")

    return True


def pexpect_child_interact_manually(child, msg):
    """docker attach interactive loop"""
    while True:
        print(f"\n pexpect_child_interact_manually: {msg}\n")
        # attach and type manually to bypass
        pexpect_child_interact(child, msg)
        if query_yes_no("{prompt} complete ?", default="no"):
            break


def qemu_child_from_hostbin():
    IMGFILE = sh.mktemp("--dry-run")
    IMGFILE = IMGFILE.strip()

    sh.ls(f"{DEFAULT_IMAGE_LOC}/{MACHINE}/flash-{MACHINE}")
    sh.cp(f"{DEFAULT_IMAGE_LOC}/{MACHINE}/flash-{MACHINE}", IMGFILE)
    sh.truncate("-s", "128M", IMGFILE)

    args = ["-M", "fby35-bmc"]
    args += ["-drive", f"if=mtd,format=raw,file={IMGFILE}"]
    args += [
        "-net",
        "nic",
        "-net",
        f"user,hostfwd=::{HTTPS_PORT}-:443,hostfwd=::{SSH_PORT}-:22,hostname=qemu",
    ]
    args += ["-nographic"]

    print(args)
    try:
        child = pexpect.spawn(
            QEMU_BIN,
            args,
            timeout=None,
            encoding="utf-8",
        )

        child.logfile = sys.stdout
    except Exception as e:  # pylint: disable=broad-except
        print("pexpect_child_from_hostbin: spawn")
        print(e)
        sys.exit("send/expect failed")

    return child, IMGFILE


def qemu_child_persist_interact(docker):
    child, file = pexpect_child_from_container(docker)
    # docker container is persistent, attach to an existing container
    # and interactive exit the shell to a login prompt point
    while True:
        pexpect_child_interact(child, "logout")
        if query_yes_no("Logged out ?", default="no"):
            break

    return child, file


def qemu_child_new_container(args):
    print("qemu_child_new_container")
    qemuargs = args + [
        "--publish-all",
        "--interactive",
        "--detach",
        "--sig-proxy=false",
        "--user",
        "root",
        "--env",
        f"HOME={OBMC_QEMU_BUILD_DIR}",
        "--env",
        f"OBMC_QEMU_BUILD_DIR={OBMC_QEMU_BUILD_DIR}",
        "--env",
        f"QEMU_ARCH={QEMU_ARCH}",
        "--env",
        f"QEMU_BIN={QEMU_BIN}",
        "--env",
        f"MACHINE={MACHINE_QEMU}",
        "--env",
        f"DEFAULT_IMAGE_LOC={DEFAULT_IMAGE_LOC}",
        "--env",
        f"SSH_PORT={SSH_PORT}",
        "--env",
        f"HTTPS_PORT={HTTPS_PORT}",
        "--workdir",
        f"{OBMC_QEMU_BUILD_DIR}",
        "--volume",
        f"{UPSTREAM_WORKSPACE}:{OBMC_QEMU_BUILD_DIR}:ro",
        "--tty",
        DOCKER_IMG_NAME,
        f"{OBMC_QEMU_BUILD_DIR}/boot-qemu-test.py",
    ]
    OBMC_QEMU_DOCKER = docker_run(qemuargs, "OBMC_QEMU_DOCKER")
    child, ret1 = pexpect_child_from_container(OBMC_QEMU_DOCKER)
    return child, None, qemuargs, OBMC_QEMU_DOCKER


def qemu_child_get_ip(container):
    # originally from a docker inspect

    print("qemu_child_get_ip: ")
    json_stream = docker_inspect_check(container)
    if not json_stream:
        sys.exit("container creation failed")

    json_data = json.loads(json_stream)

    ip_address = (json_data[0]["NetworkSettings"])["IPAddress"]
    if ip_address == "" and DOCKER != "podman":
        sys.exit(f"IPAddress={ip_address} bogus")
    print(f"OBMC_QEMU_DOCKER={OBMC_QEMU_DOCKER}, IPAddress={ip_address}")
    return ip_address


def host_networking_arg(net):
    if net:
        return ["--network=host"]
    else:
        return []


# main:
def main():
    """main method"""
    global OBMC_QEMU_DOCKER
    global DOCKER_IMG_NAME
    global HOSTNETWORKING
    child = None

    file = None
    ip_address = "127.0.0.1"
    qemuargs = ""

    DOCKER_IMG_NAME = docker_build_pull_image(DOCKER_IMG_NAME)

    if KEEP_QEMU_PERSISTENT:
        rm_arg = []
    else:
        rm_arg = ["--rm"]

    #    # Copy container scripts
    #    sh.cp(glob.glob(DIR + "/scripts/boot-qemu*"), UPSTREAM_WORKSPACE)
    sh.cp(f"{DIR}/scripts/boot-qemu-test.py", UPSTREAM_WORKSPACE)
    sh.ls("-al", f"{UPSTREAM_WORKSPACE}/boot-qemu-test.py")

    # ### main ###
    if LAUNCH == "local":
        # Start QEMU docker instance
        # root in docker required to open up the https/ssh ports
        if HOSTBIN:
            HOSTNETWORKING = True
            if not HOSTBINPERSIST:
                # spawn new qemu host networking
                child, file = qemu_child_from_hostbin()
                pexpect_child_send_expect(child)
            # use existing qemu, manually set to a ready state
        else:
            if OBMC_QEMU_DOCKER:
                print("exit to login prompt >")
                child, file = qemu_child_persist_interact(OBMC_QEMU_DOCKER)
            else:
                # new container instance
                child, file, qemuargs, OBMC_QEMU_DOCKER = (
                    qemu_child_new_container(
                        host_networking_arg(HOSTNETWORKING) + rm_arg
                    )
                )
                print(qemuargs)

            print(f"OBMC_QEMU_DOCKER={OBMC_QEMU_DOCKER} before")

            if INTERACT:
                # manual login
                print("main: interactive pass-through")
                pexpect_child_interact_manually(child, "pass-through")
            else:
                # send/expect and then retry on timeout
                print("main: non-interactive")
                if not pexpect_child_send_expect(child):
                    pexpect_child_interact_manually(child, "manual fallback")

            ip_address = qemu_child_get_ip(OBMC_QEMU_DOCKER)
            child = None

        print("main:")
        now = datetime.now()

        # Timestamp for job
        print("Robot Test started, " + now.strftime("%Y-%m-%d %H:%M:%S"))

        # use shell semantics instead
        # os.mkdir("-p", WORKSPACE)
        sh.mkdir("-p", WORKSPACE)

        # Copy in the script which will execute the Robot tests
        sh.cp(f"{DIR}/scripts/run-robot.sh", WORKSPACE)
        # os.copyfile(f"{DIR}/scripts/run-robot.sh", WORKSPACE)

        sh.ls(WORKSPACE)

        # "--detach",
        args = (
            rm_arg
            + proxy_args
            + host_networking_arg(HOSTNETWORKING)
            + [
                "--env",
                f"HOME={HOME}",
                "--env",
                f"IP_ADDR={ip_address}",  # use host IP address on hostbin
                "--env",
                f"SSH_PORT={SSH_PORT}",
                "--env",
                f"HTTPS_PORT={HTTPS_PORT}",
                "--env",
                f"MACHINE={MACHINE_QEMU}",
                "--workdir",
                HOME,
                "--volume",
                f"{WORKSPACE}:{HOME}",
                "--tty",
                "--interactive",
                DOCKER_IMG_NAME,
                f"{HOME}/run-robot.sh",
            ]
        )

        print(args)
        # Run the Docker container to execute the Robot test cases
        # The test results will be put in ${WORKSPACE}
        OBMC_ROBOT_DOCKER = docker_run(args, "obmc_robot_docker")
        print(f"OBMC_ROBOT_DOCKER={OBMC_ROBOT_DOCKER}")

        if not (KEEP_QEMU_PERSISTENT or HOSTBINPERSIST):
            docker_stop(OBMC_QEMU_DOCKER, "persistent QEMU container")

        print(f"file={file}")
        if file:
            sh.rm(file)

    else:
        sys.exit("LAUNCH variable invalid, Exiting")


if __name__ == "__main__":
    main()
