#!/usr/bin/env python3
#
# This is run inside a container and performs setup with networking

import os
import shutil
import socket
import subprocess
import sys
from pathlib import Path

import sh

SSH_PORT = os.environ.get("SSH_PORT", False)
if not SSH_PORT:
    sys.exit("Docker SSH_PORT not defined")

HTTPS_PORT = os.environ.get("HTTPS_PORT", False)
if not HTTPS_PORT:
    sys.exit("Docker HTTPS_PORT not defined")

QEMU_BIN = os.environ.get("QEMU_BIN", False)
if not QEMU_BIN:
    sys.exit("QEMU_BIN not defined")

DOCKER = os.environ.get("DOCKER", False)
if not DOCKER:
    sys.exit("DOCKER not defined")

DEFAULT_MACHINE = "versatilepb"

MACHINE = os.environ.get("MACHINE", DEFAULT_MACHINE)

# Quirks hash to map the machine image to the qemu model.
# Edit as needed to remap models.
model = {
    "yosemite4": "fby35",
}

if MACHINE in model:
    MODEL = model[MACHINE]
    print(f"in model MODEL = {MODEL}, MACHINE = {MACHINE}")
else:
    print(f"MACHINE = MODEL = {MACHINE}")
    MODEL = MACHINE

# Find the correct drive file, and save its name.  OpenBMC has 3 different
# image formats.  The UBI based one, the standard static.mtd one, and the
# default QEMU basic image (rootfs.ext4).

# if not set then default
DEFAULT_IMAGE_LOC = os.environ.get("DEFAULT_IMAGE_LOC", "./tmp/deploy/images")

IMAGEPATH = f"{DEFAULT_IMAGE_LOC}/{MACHINE}/"

p = Path(IMAGEPATH)

# Example
# tmp/deploy/images/romulus/obmc-phosphor-image-romulus.static.mtd
# tmp/deploy/images/romulus/obmc-phosphor-image-romulus-20250123220306.static.mtd

dlist = list(p.glob(f"obmc-phosphor-image-{MACHINE}*.mtd"))

# Directory symbolic link structure example:
# ./build-yosemite4/tmp/deploy/images/yosemite4/flash-yosemite4 ->
#    obmc-phosphor-image-yosemite4-20240509200304.static.mtd
# ./build-yosemite4/tmp/deploy/images/yosemite4/\
#    obmc-phosphor-image-yosemite4-20240509200304.static.mtd
if dlist:
    head, tail = os.path.split(dlist[0])
    DRIVE = str(tail)
else:
    sys.exit(f"flash image not found in: {IMAGEPATH}")

# Copy the drive file off to /tmp so that QEMU does not write anything back
# to the drive file and make it unusable for future QEMU runs.
TMP_DRIVE_PATH = str(sh.mktemp(f"/tmp/{DRIVE}-XXXXX")).rstrip()

if MACHINE == DEFAULT_MACHINE:
    shutil.copyfile(f"{DEFAULT_IMAGE_LOC}/qemuarm/{DRIVE}", TMP_DRIVE_PATH)
else:
    shutil.copyfile(f"{DEFAULT_IMAGE_LOC}/{MACHINE}/{DRIVE}", TMP_DRIVE_PATH)

ghn = socket.gethostname()
print(f"gethostname = {ghn}")  # returns "robot" in podman

try:
    IP = socket.gethostbyname(ghn)
except Exception as e:  # failure results in localhost
    print(e)
    IP = "127.0.0.1"


# Remap ports when using host networking
# This example maps 22 -> 2222 and keeps 8080 -> 8080
#
# ["-net", "user,hostfwd=::2222-:22,hostfwd=::8080-:8080,hostname=qemu"]

# qemu network forwarding
NET_FORWARDING = (
    f"hostfwd=:{IP}:{SSH_PORT}-:22,"
    f"hostfwd=:{IP}:{HTTPS_PORT}-:443,"
    f"hostfwd=tcp:{IP}:80-:80,"
    f"hostfwd=udp:{IP}:623-:623"
    f"hostfwd=udp:{IP}:664-:664,"
    f"hostfwd=tcp:{IP}:2200-:2200,"
)

# Most system only have one NIC so set this as default
if MACHINE == "tacoma":
    # Tacoma requires us to specify up to four NICs, with the third one being
    # the active device.
    NIC = [
        "-net",
        "nic,model=ftgmac100,netdev=netdev1",
        "-netdev",
        "user,id=netdev1",
    ]
    NIC = NIC + [
        "-net",
        "nic,model=ftgmac100,netdev=netdev2",
        "-netdev",
        "user,id=netdev2",
    ]
    NIC = NIC + [
        "-net",
        "nic,model=ftgmac100,netdev=netdev3",
        "-netdev",
        f"user,id=netdev3,{NET_FORWARDING}",
    ]
    NIC = NIC + [
        "-net",
        "nic,model=ftgmac100,netdev=netdev4",
        "-netdev",
        "user,id=netdev4",
    ]
else:
    # do not use qemu netdev for podman as SLIRP networking conflicts with podman
    # use native podman networking instead. Reconsider pushing forwarding rules
    # into podman/docker command line args
    if DOCKER == "podman":
        NIC = [
            "-net",
            "nic",
            "-net",
            f"user,hostfwd=::{HTTPS_PORT}-:443,hostfwd=::{SSH_PORT}-:22,hostname=qemu",
        ]
    else:
        NIC = [
            "-net",
            "nic,model=ftgmac100,netdev=netdev1",
            "-netdev",
            f"user,id=netdev1,{NET_FORWARDING}",
        ]

args = []

# Special case handle
if MACHINE == DEFAULT_MACHINE:
    # Launch default QEMU using the qemu-system-arm
    args = args + [
        "-device",
        "virtio-net,netdev=mynet",
        "-netdev",
        f"user,id=mynet,{NET_FORWARDING}" "-machine",
        f"{DEFAULT_MACHINE}",
        "-m",
        "256",
        "-drive",
        f"file={TMP_DRIVE_PATH},if=virtio,format=raw",
        "-show-cursor",
        "-usb",
        "-usbdevice",
        "tablet",
        "-device",
        "virtio-rng-pci",
        "-serial",
        "mon:vc",
        "-serial",
        "mon:stdio",
        "-serial",
        "null",
        "-kernel",
        f"{DEFAULT_IMAGE_LOC}/qemuarm/zImage",
        "-append",
        "'root=/dev/vda rw highres=off  console=ttyS0 mem=256M "
        + "ip=dhcp console=ttyAMA0,115200 console=tty'",
        "-dtb",
        f"{DEFAULT_IMAGE_LOC}/qemuarm/zImage-versatile-pb.dtb",
    ]
else:
    args = (
        args
        + [
            "-machine",
            f"{MODEL}-bmc",
            "-nographic",
            "-drive",
            f"file={TMP_DRIVE_PATH},format=raw,if=mtd",
        ]
        + NIC
    )

# Launch qemu and leave running
# TODO
try:
    run_args = [QEMU_BIN] + args
    print(run_args)
    ret = subprocess.run(run_args)
    if ret.returncode != 0:
        sys.exit("qemu failed")
except Exception as e:
    print(e)

os.remove(TMP_DRIVE_PATH)
