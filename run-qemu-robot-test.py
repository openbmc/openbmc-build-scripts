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
#  OBMC_QEMU_DOCKER   = Use a persistent Docker container if set and valid
#  KEEP_PERSISTENT    = None
#  INTERACT           = None
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


def docker_inspect_check(container, exit_failed=True):
    """docker inspect and return JSON contents"""
    # Sanity check:
    ret = subprocess.run(
        ["docker", "inspect", container], capture_output=True, check=False
    )
    if ret.returncode != 0:
        if exit_failed:
            sys.exit("docker-inspect: failed " + container)
    else:
        print("docker-inspect: succeeded " + container)
    return ret


# originally from
#  https://stackoverflow.com/\
#  questions/3718657/how-do-you-properly-determine-the-current-script-directory
def get_script_dir(follow_symlinks=True):
    """Get the script working directory"""
    if getattr(sys, "frozen", False):
        path = os.path.abspath(sys.executable)
    else:
        path = inspect.getabsfile(get_script_dir)
    if follow_symlinks:
        path = os.path.realpath(path)
    return os.path.dirname(path)


KEEP_PERSISTENT = None
PERSISTQEMU = None
OBMC_QEMU_DOCKER = None
INTERACT = None
LAUNCH = None
OBMC_QEMU_BUILD_DIR = None
QEMU_ARCH = None
QEMU_BIN = None
MACHINE = None
DEFAULT_IMAGE_LOC = None
SSH_PORT = None
HTTPS_PORT = None
UPSTREAM_WORKSPACE = None
DOCKER_IMG_NAME = None
DIR = None
WORKSPACE = None
HOME = None
MACHINE_QEMU = None
DEFAULT_MACHINE = None
ret = None

HOME = str(os.environ["HOME"])

RANDOM = "blah"
WORKSPACE = os.environ.get("WORKSPACE", f"{HOME}/{RANDOM}{RANDOM}")  # TODO
DOCKER_IMG_NAME = os.environ.get(
    "DOCKER_IMG_NAME", "openbmc/ubuntu-robot-qemu"
)

OBMC_QEMU_BUILD_DIR = os.environ.get(
    "OBMC_QEMU_BUILD_DIR", "/tmp/openbmc/build"
)

UPSTREAM_WORKSPACE = os.environ.get("UPSTREAM_WORKSPACE", "False")
if UPSTREAM_WORKSPACE == "False":
    sys.exit("env var UPSTREAM_WORKSPACE is required and not set")

LAUNCH = os.environ.get("LAUNCH", "local")
print(f"LAUNCH={LAUNCH}")

MACHINE = os.environ.get("MACHINE", DEFAULT_MACHINE)

if os.environ.get("KEEP_PERSISTENT", "False") != "False":
    print("KEEP_PERSISTENT True")
    KEEP_PERSISTENT = True
else:
    print("KEEP_PERSISTENT False")
    KEEP_PERSISTENT = False

OBMC_QEMU_DOCKER = os.environ.get("OBMC_QEMU_DOCKER", "False")
if OBMC_QEMU_DOCKER != "False":
    ret = docker_inspect_check(OBMC_QEMU_DOCKER, exit_failed=False)
    if ret.returncode == 0:  # success on '0'
        print("PERSISTQEMU True")
        PERSISTQEMU = True
    else:  # means it's invalid
        print("PERSISTQEMU False")
        PERSISTQEMU = False
else:
    print("PERSISTQEMU False")
    PERSISTQEMU = False


DEFAULT_IMAGE_LOC = os.environ.get("DEFAULT_IMAGE_LOC", "/tmp/deploy/images/")

if os.environ.get("INTERACT", "False") != "False":
    print("INTERACT True")
    INTERACT = True
else:
    print("INTERACT False")
    INTERACT = False

# Determine the prefix of the Dockerfile's base image and the QEMU_ARCH
# variable
ARCH = os.uname().machine
match ARCH:
    case "ppc64le":
        QEMU_ARCH = "ppc64le-linux"
    case "x86_64":
        QEMU_ARCH = "x86_64-linux"
    case "aarch64":
        QEMU_ARCH = "arm64-linux"
    case _:
        sys.exit(
            f"Unsupported system architecture({ARCH})"
            " found for docker image"
        )

# Set the location of the qemu binary relative to UPSTREAM_WORKSPACE
QEMU_BIN = os.environ.get(
    "QEMU_BIN", f"./tmp/sysroots/{QEMU_ARCH}/usr/bin/qemu-system-arm"
)

# We can use default ports because we're going to have the 2
# docker instances talk over their private network
SSH_PORT = os.environ.get("SSH_PORT", "22")
HTTPS_PORT = os.environ.get("HTTPS_PORT", "443")

if os.environ.get("hostbin", "False") == "False":
    hostbin = False
else:
    hostbin = True

# Get the base directory of the openbmc-build-scripts repo so we can return
DIR = get_script_dir()

# TODO
# optional: might wanna check to see if it exists before running this script
# on CI systems.
#
# Create the base Docker image for QEMU and Robot
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

# The automated test suite needs a real machine type so
# if we're using versatilepb for our qemu start parameter
# then we need to just let our run-robot use the default
DEFAULT_MACHINE = "versatilepb"
if MACHINE == DEFAULT_MACHINE:
    MACHINE_QEMU = ""
else:
    MACHINE_QEMU = MACHINE


def pexpect_child_interact(child, msg):
    """docker attach ARGS for an interactive session"""
    print(f"pexpect_child_interact: {msg}")
    ret = subprocess.run(["docker", "attach", OBMC_QEMU_DOCKER], check=False)
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
        subprocess.run(["docker", "stop", container], check=True)
        subprocess.run(["docker", "rm", container], check=True)
    except subprocess.CalledProcessError as e:
        print(e)


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


child = None


def pexpect_child_from_host():
    FB_MACHINE = "yosemite4"
    IMGPATH = f"{HOME}/local/builds/build-{FB_MACHINE}/tmp/deploy/images/{FB_MACHINE}"
    IMGFILE = sh.mktemp("--dry-run")
    IMGFILE = IMGFILE.strip()

    sh.ls(f"{IMGPATH}/flash-{FB_MACHINE}")
    sh.cp(f"{IMGPATH}/flash-{FB_MACHINE}", IMGFILE)
    sh.truncate("-s", "128M", IMGFILE)

    exe = "/home/bhuey/local/builds/qemu/build/qemu-system-arm"

    args = ["-M", "fby35-bmc"]
    args += ["-drive", f"if=mtd,format=raw,file={IMGFILE}"]
    args += [
        "-net",
        "nic",
        "-net",
        "user,hostfwd=::4443-:443,hostfwd=::2222-:22,hostfwd=::8080-:8080,hostname=qemu",
    ]
    args += ["-nographic"]

    print(args)
    try:
        child = pexpect.spawn(
            #            "bmcqemu", ["pathtoimage"], timeout=None, encoding="utf-8"
            exe,
            args,
            timeout=None,
            encoding="utf-8",
        )

        child.logfile = sys.stdout
    except Exception as e:  # pylint: disable=broad-except
        print("pexpect_child_from_host: spawn")
        print(e)
        sys.exit("send/expect failed")

    return child, IMGFILE


def pexpect_child_from_container(container):
    try:
        child = pexpect.spawn(
            "docker", ["attach", container], timeout=None, encoding="utf-8"
        )

        child.logfile = sys.stdout
    except Exception as e:  # pylint: disable=broad-except
        print("pexpect_child_from_container: ")
        print(e)
        sys.exit("send/expect failed")

    return child, None


def pexpect_child_close(child):
    if not hostbin:
        child.close()  # attach close
        child.logfile.close()
        return True

    return False


def pexpect_child_send_expect(child):
    """send/expect prompt match"""
    print("pexpect_child_send_expect:")

    def match_token(match, mesg):
        """Returning 0 is success"""
        if match == 0:
            emsg = f"got {mesg}"
            ret = 0

        expecting = f"expecting {mesg}"

        if match > 0:
            if match == 1:
                emsg = f"got EOF, {expecting}"
                ret = 1
            if match == 2:
                emsg = f"got TIMEOUT, {expecting}"
                print(emsg)
                if match > 2:
                    print("uncaught index")

            sys.exit("uncaught send/expect index")

        return ret

    timeoutlist = [pexpect.EOF, pexpect.TIMEOUT]

    def mlist(token):
        return [token] + timeoutlist

    child.sendline("")

    try:
        while True:
            match = child.expect(mlist(".* login: "), timeout=1000)
            if match_token(match, "login"):
                continue

            child.sendline("root")

            match = child.expect(mlist("Password:"), timeout=1000)
            if match_token(match, "password"):
                continue

            child.sendline("0penBmc")

            # root@yosemite4:~#
            match = child.expect(mlist(".*root@.*:~#.*"), timeout=1000)
            if match_token(match, "prompt"):
                continue
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


# TODO
def docker_stop(container, m):
    """docker stop"""
    try:
        subprocess.run(["docker", "stop", container], check=True)
    except subprocess.CalledProcessError as e:
        print(f"docker_stop: {m}")
        print(e)


# TODO
def docker_run(args, m):
    """docker run"""
    print(args)
    try:
        print(f"docker_run: {args}")
        ret = subprocess.run(
            ["docker", "run"] + args, capture_output=True, check=True
        )
        print(f"docker-run: ret={ret}")
    except subprocess.CalledProcessError as e:
        print(e)
        sys.exit(f"docker-run failed {m}")

    c = ret.stdout.decode("utf-8").rstrip()
    print(f"docker-run: {m}={c}")
    return c


# main:
def main():
    """main method"""
    print(f"LAUNCH={LAUNCH}")
    global OBMC_QEMU_DOCKER
    global child

    ip_address = "127.0.0.1"
    docker_inspect = False
    hostnetworking = False
    networkargs = []
    rm = ["--rm"]

    if KEEP_PERSISTENT:
        rm = []

    #    # Copy container scripts
    #    sh.cp(glob.glob(DIR + "/scripts/boot-qemu*"), UPSTREAM_WORKSPACE)
    sh.cp(f"{DIR}/scripts/boot-qemu-test.py", UPSTREAM_WORKSPACE)
    sh.ls("-al", f"{UPSTREAM_WORKSPACE}/boot-qemu-test.py")

    # ### main ###
    if LAUNCH == "local":
        # Start QEMU docker instance
        # root in docker required to open up the https/ssh ports

        if hostbin:
            hostnetworking = True

            child, file = pexpect_child_from_host()
            pexpect_child_send_expect(child)
        else:
            if PERSISTQEMU:
                docker_inspect = True
                print("exit to login prompt >")
                child, file = pexpect_child_from_container(OBMC_QEMU_DOCKER)
                # docker container is persistent, attach to an existing container
                # and interactive exit the shell to a login prompt point
                while True:
                    pexpect_child_interact(child, "logout")
                    if query_yes_no("Logged out ?", default="no"):
                        break
            else:
                docker_inspect = True
                args = rm + [
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
                OBMC_QEMU_DOCKER = docker_run(args, "OBMC_QEMU_DOCKER")
                child, file = pexpect_child_from_container(OBMC_QEMU_DOCKER)

            if docker_inspect:
                # originally from a docker inspect
                # podman run --platform linux/amd64 --ulimit=host --network=host -dti harbor.thefacebook.com/lf_openbmc/ubuntu/openbmc-qemu-docker:experimental /bin/bash

                print("after run")
                ret = docker_inspect_check(OBMC_QEMU_DOCKER)

                json_stream = ret.stdout.decode("utf-8").rstrip()
                json_data = json.loads(json_stream)

                ip_address = (json_data[0]["NetworkSettings"])["IPAddress"]
                if ip_address == "":
                    sys.exit(f"IPAddress={ip_address} bogus")
                print(
                    f"OBMC_QEMU_DOCKER={OBMC_QEMU_DOCKER}, IPAddress={ip_address}"
                )

            if INTERACT:  # only if it's a docker/podman container
                # manual login
                print("interactive pass-through")
                pexpect_child_interact_manually(child, "pass-through")
            else:
                # send/expect and then manually fallback on a timeout
                print("non-interactive")
                if not pexpect_child_send_expect(child):
                    pexpect_child_interact_manually(child, "manual fallback")

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

        #  podman run --platform linux/amd64 --ulimit=host --network=host -dti harbor.thefacebook.com/lf_openbmc/ubuntu/openbmc-qemu-docker:experimental /bin/bash

        if hostnetworking:
            networkargs = ["--network=host"]

        args = networkargs + [
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
            #            "--rm",
            DOCKER_IMG_NAME,
            f"{HOME}/run-robot.sh",
        ]

        # Run the Docker container to execute the Robot test cases
        # The test results will be put in ${WORKSPACE}
        OBMC_ROBOT_DOCKER = docker_run(args, "obmc_robot_docker")

        if not (pexpect_child_close(child) or KEEP_PERSISTENT or PERSISTQEMU):
            docker_stop(OBMC_QEMU_DOCKER, "persistent QEMU container")

        if file:
            sh.rm("-f", file)

        print(f"OBMC_ROBOT_DOCKER={OBMC_ROBOT_DOCKER}")

    else:
        sys.exit("LAUNCH variable invalid, Exiting")


if __name__ == "__main__":
    main()
