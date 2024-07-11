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
#  obmc_qemu_docker   = Use a persistent Docker container if set and valid
#
###############################################################################

import glob
import inspect
import json
import os
import pexpect
import sh
import subprocess
import sys
from datetime import datetime
#import time
#import pprint
#import argparse
#import signal
#from pathlib import Path

keep_persistent=None
persistqemu=None
obmc_qemu_docker=None
interact=None
LAUNCH=None
OBMC_QEMU_BUILD_DIR=None
QEMU_ARCH=None
QEMU_BIN=None
MACHINE=None
DEFAULT_IMAGE_LOC=None
SSH_PORT=None
HTTPS_PORT=None
UPSTREAM_WORKSPACE=None
DOCKER_IMG_NAME=None
DIR=None
WORKSPACE=None
HOME=None
MACHINE_QEMU=None

# Get the script working directory
#
# originally from
#  https://stackoverflow.com/\
#  questions/3718657/how-do-you-properly-determine-the-current-script-directory
def get_script_dir(follow_symlinks=True):
    if getattr(sys, 'frozen', False):
        path = os.path.abspath(sys.executable)
    else:
        path = inspect.getabsfile(get_script_dir)
    if follow_symlinks:
        path = os.path.realpath(path)
    return os.path.dirname(path)

def init_environ():
    global keep_persistent
    global persistqemu
    global obmc_qemu_docker
    global interact
    global WORKSPACE
    global OBMC_QEMU_BUILD_DIR
    global LAUNCH
    global QEMU_ARCH
    global QEMU_BIN
    global MACHINE
    global DEFAULT_IMAGE_LOC
    global SSH_PORT
    global HTTPS_PORT
    global UPSTREAM_WORKSPACE
    global DOCKER_IMG_NAME
    global DIR
    global HOME
    global MACHINE_QEMU

    HOME=str(os.environ['HOME'])

    RANDOM="blah"
    WORKSPACE=os.environ.get('WORKSPACE', f"{HOME}/{RANDOM}{RANDOM}") # TODO
    DOCKER_IMG_NAME=os.environ.get('DOCKER_IMG_NAME',
        "openbmc/ubuntu-robot-qemu")

    OBMC_QEMU_BUILD_DIR=os.environ.get('OBMC_QEMU_BUILD_DIR',
        "/tmp/openbmc/build")

    try:
        UPSTREAM_WORKSPACE=os.environ['UPSTREAM_WORKSPACE']
    except Exception as e:
        e=None
        sys.exit("env var UPSTREAM_WORKSPACE is required and not set")
 
    LAUNCH=os.environ.get('LAUNCH', "local")
    print(f"LAUNCH={LAUNCH}")

    DEFAULT_MACHINE="versatilepb"
    MACHINE=os.environ.get('MACHINE', DEFAULT_MACHINE)

    if os.environ.get('keep_persistent', "False") != "False":
        print("keep_persistent True")
        keep_persistent=True
    else:
        print("keep_persistent False")
        keep_persistent=False

    obmc_qemu_docker=os.environ.get('obmc_qemu_docker', "False")
    if obmc_qemu_docker != "False":
        ret = docker_inspect_check(obmc_qemu_docker, exit_failed=False)
        if ret.returncode == 0: # success on '0'
            print("persistqemu True")
            persistqemu=True
        else:
            print("persistqemu False")
            persistqemu=False

    DEFAULT_IMAGE_LOC=os.environ.get('DEFAULT_IMAGE_LOC', "/tmp/deploy/images/")

    if (os.environ.get("interact", "False") != "False"):
        print("interact True")
        interact=True
    else:
        print("interact False")
        interact=False

    # Determine the prefix of the Dockerfile's base image and the QEMU_ARCH
    # variable
    ARCH=os.uname().machine
    match ARCH:
        case "ppc64le":
            QEMU_ARCH="ppc64le-linux"
        case "x86_64":
            QEMU_ARCH="x86_64-linux"
        case "aarch64":
            QEMU_ARCH="arm64-linux"
        case _:
            sys.exit(
            f"Unsupported system architecture({ARCH}) found for docker image")

    # Set the location of the qemu binary relative to UPSTREAM_WORKSPACE
    QEMU_BIN=os.environ.get('QEMU_BIN',
        f"./tmp/sysroots/{QEMU_ARCH}/usr/bin/qemu-system-arm")

    # We can use default ports because we're going to have the 2
    # docker instances talk over their private network
    SSH_PORT=os.environ.get('SSH_PORT', "22")
    HTTPS_PORT=os.environ.get('HTTPS_PORT', "443")

    # Get the base directory of the openbmc-build-scripts repo so we can return
    DIR=get_script_dir()

    # TODO
    # optional: might wanna check to see if it exists before running this script
    # on CI systems.
    #
    # Create the base Docker image for QEMU and Robot
    try:
        ret = subprocess.run([DIR + "/scripts/build-qemu-robot-docker.sh",
            DOCKER_IMG_NAME])
    except subprocess.CalledProcessError as e:
        print(e)
        sys.exit("Failed to create docker")

    # The automated test suite needs a real machine type so
    # if we're using versatilepb for our qemu start parameter
    # then we need to just let our run-robot use the default
    if MACHINE == DEFAULT_MACHINE:
        MACHINE_QEMU=""
    else:
        MACHINE_QEMU=MACHINE

def docker_inspect_check(container, exit_failed=True):
    # Sanity check:
    ret = subprocess.run(["docker", "inspect", container], capture_output=True)
    if ret.returncode != 0:
        if exit_failed:
            sys.exit("docker-inspect: failed " + container)
    else:
        print("docker-inspect: succeeded " + container)
    return ret

#Remove
def docker_attach_run(m):
    print("docker_attach_run:")
    ret = subprocess.run(["docker", "attach", obmc_qemu_docker])
    if ret.returncode != 0:
        # returncode = 1 is ok
        if ret.returncode != 1:
            print(ret)
            sys.exit("docker-attach-run: failed {m}")

def docker_attach_interact(m):
    print("docker_attach_interact:")
    ret = subprocess.run(["docker", "attach", obmc_qemu_docker])
    if ret.returncode != 0:
        # returncode = 1 is ok
        if ret.returncode != 1:
            print(ret)
            sys.exit("docker-attach: failed {m}")

    print("docker-attach: succeeded {m}")

def signal_handler(sig, frame):
    print("signal hander")
    print(sig)
    print(frame)

#TODO
def docker_kill(container):
    try:
        subprocess.run(["docker", "stop", container])
        subprocess.run(["docker", "rm", container])
    except subprocess.CalledProcessError as e:
        print(e)

#TODO
def clean_up():
    print("Ctrl + C interrupt, cleaning up now")

    docker_kill(obmc_qemu_docker)
    subprocess.run(["docker", "ps", "-a"])

# Recipe from https://code.activestate.com/recipes/577058/
#
def query_yes_no(question, default="yes"):
    """Ask a yes/no question via raw_input() and return their answer.

    "question" is a string that is presented to the user.
    "default" is the presumed answer if the user just hits <Enter>.
            It must be "yes" (the default), "no" or None (meaning
            an answer is required of the user).

    The "answer" return value is True for "yes" or False for "no".
    """
    valid = {"yes": True, "y": True, "ye": True, "no": False, "n": False}
    if default is None:
        prompt = " [y/n] "
    elif default == "yes":
        prompt = " [Y/n] "
    elif default == "no":
        prompt = " [y/N] "
    else:
        raise ValueError("invalid default answer: '%s'" % default)

    while True:
        sys.stdout.write(question + prompt)
        choice = input().lower()
        if default is not None and choice == "":
            return valid[default]
        elif choice in valid:
            return valid[choice]
        else:
            sys.stdout.write(
                "Please respond with 'yes' or 'no' " "(or 'y' or 'n').\n")

def match_it(match, mesg):
    if (match == 0):
        print(mesg)
        return 0
    elif (match == 1):
        print("timeout")
        return 1
    else:
        print("unexpected index")
        return 2

def docker_attach_send_expect(container):
    print("docker_attach_send_expect:")

    timeoutlist=["Login timed out after 60 seconds."]
    try:
        # docker-attach
        child = pexpect.spawn("docker", ["attach", container],
            timeout=None, encoding='utf-8')
        child.delaybeforesend = 0.5

        child.logfile = sys.stdout

        child.sendline('')
        while True:
            match = child.expect(['.* login: '] + timeoutlist)
            if match_it(match, "got login"):
                continue

            child.sendline('root')

            match = child.expect(['Password:'] + timeoutlist)
            if match_it(match, "got password"):
                continue

            child.sendline('0penBmc')

            #root@yosemite4:~#
            match = child.expect(['.*root@.*:~#.*'] + timeoutlist)
            if match_it(match, "got prompt"):
                continue
            else:
                break

        child.sendline('')
    except Exception as e:
        print("docker_attach_send_expect: exception")
        print(e)
        return False

    child.close() # attach close
    return True

def docker_attach_interact_manually(prompt):
    while True:
        print(f"\n docker_attach_interact_manually: {prompt}\n")
        #attach and type manually to bypass
        docker_attach_interact(prompt)
        if query_yes_no("{prompt} complete ?", default="no"):
            break

#TODO
def docker_stop(container, m):
    try:
        subprocess.run(["docker",  "stop", container])
    except subprocess.CalledProcessError as e:
        print(f"docker_stop: {m}")
        print(e)

#TODO
def docker_run(args, m):
    print(args)
    try:
        print(f"docker_run: {args}")
        ret = subprocess.run(
            args,
            capture_output=True)
        print(f"docker-run: ret={ret}")
    except subprocess.CalledProcessError as e:
        print(e)
        sys.exit(f"docker-run failed {m}")

    c = ret.stdout.decode("utf-8").rstrip()
    print(f"docker-run: {m}={c}")
    return c

# main:
def main():
    global obmc_qemu_docker
    init_environ()
    print(f"LAUNCH={LAUNCH}")

    if keep_persistent:
        rm=[]
    else:
        rm=["--rm"]
    
#    # Copy container scripts
#    sh.cp(glob.glob(DIR + "/scripts/boot-qemu*"), UPSTREAM_WORKSPACE)
    sh.cp(f"{DIR}/scripts/boot-qemu-test.py", UPSTREAM_WORKSPACE)
    sh.ls("-al", f"{UPSTREAM_WORKSPACE}/boot-qemu-test.py")

    # ### main ###
    if LAUNCH == "local":
        # Start QEMU docker instance
        # root in docker required to open up the https/ssh ports
    
        if persistqemu:
            print("exit to login prompt >")
            # docker container is persistent, attach to an existing container
            # and interactive exit the shell to a login prompt point
            while True:
                docker_attach_interact("logout")
                if query_yes_no("Logged out ?", default="no"):
                    break
        else:
            args= ["docker", "run"] + rm + [
                "--interactive",
                "--detach",
                "--sig-proxy=false",
                "--user",   "root",
                "--env",    f"HOME={OBMC_QEMU_BUILD_DIR}",
                "--env",    f"OBMC_QEMU_BUILD_DIR={OBMC_QEMU_BUILD_DIR}",
                "--env",    f"QEMU_ARCH={QEMU_ARCH}",
                "--env",    f"QEMU_BIN={QEMU_BIN}",
                "--env",    f"MACHINE={MACHINE}",
                "--env",    f"DEFAULT_IMAGE_LOC={DEFAULT_IMAGE_LOC}",
                "--env",    f"SSH_PORT={SSH_PORT}",
                "--env",    f"HTTPS_PORT={HTTPS_PORT}",
                "--workdir", f"{OBMC_QEMU_BUILD_DIR}",
                "--volume",
                    f"{UPSTREAM_WORKSPACE}:{OBMC_QEMU_BUILD_DIR}:ro",
                "--tty",
                DOCKER_IMG_NAME,
                f"{OBMC_QEMU_BUILD_DIR}/boot-qemu-test.py"]
            obmc_qemu_docker = docker_run(args, "obmc_qemu_docker")
    
        print("main:")
    
        # This docker command intermittently asserts a SIGPIPE which
        # causes the whole script to fail. The IP address comes through
        # fine on these errors so just ignore the SIGPIPE
    
        # originally from a docker inspect
        print("after run")
        ret = docker_inspect_check(obmc_qemu_docker)
    
        json_stream=ret.stdout.decode("utf-8").rstrip()
        json_data=json.loads(json_stream)
    
        IPAddress=(json_data[0]["NetworkSettings"])["IPAddress"]
        if IPAddress == "":
            sys.exit(f"IPAddress={IPAddress} bogus")
        print(f"obmc_qemu_docker={obmc_qemu_docker}, IPAddress={IPAddress}")
    
        if interact:
            # manual login
            print("interactive pass-through")
            docker_attach_interact_manually("pass-through")
        else:
            # send/expect and then manually fallback on a timeout
            print("non-interactive")
            if not docker_attach_send_expect(obmc_qemu_docker):
                docker_attach_interact_manually("manual fallback")
    
        now = datetime.now()
    
        # Timestamp for job
        print("Robot Test started, " + now.strftime("%Y-%m-%d %H:%M:%S"))

        # use shell semantics instead
        #os.mkdir("-p", WORKSPACE)
        sh.mkdir("-p", WORKSPACE)
    
        # Copy in the script which will execute the Robot tests
        sh.cp(f"{DIR}/scripts/run-robot.sh", WORKSPACE)
        #os.copyfile(f"{DIR}/scripts/run-robot.sh", WORKSPACE)
    
        args=["docker", "run",
            "--env",     f"HOME={HOME}",
            "--env",     f"IP_ADDR={IPAddress}",
            "--env",     f"SSH_PORT={SSH_PORT}",
            "--env",     f"HTTPS_PORT={HTTPS_PORT}",
            "--env",     f"MACHINE={MACHINE_QEMU}",
            "--workdir", HOME,
            "--volume",  f"{WORKSPACE}:{HOME}",
            "--tty",
            "--rm",
            DOCKER_IMG_NAME, f"{HOME}/run-robot.sh"]
    
        # Run the Docker container to execute the Robot test cases
        # The test results will be put in ${WORKSPACE}
        docker_run(args, "obmc_robot_docker")
    
        if not keep_persistent and not persistqemu:
            docker_stop(obmc_qemu_docker, "persistent QEMU container")
    else:
        sys.exit("LAUNCH variable invalid, Exiting")
    
if __name__ == "__main__":
    main()
