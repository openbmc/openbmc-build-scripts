#!/usr/bin/python3
# Container setup with networking

import pexpect
import pprint
import os
import re
import sys
import time
import subprocess
import sh
from pathlib import Path
from sh import rm

try:
    QEMU_BIN=os.environ['QEMU_BIN']
except Exception as e:
    print(e)
    sys.exit("QEMU_BIN not defined")

DEFAULT_MACHINE="versatilepb"

try:
    MACHINE=os.environ['MACHINE']
except Exception as e:
    MACHINE=DEFAULT_MACHINE

# special
if MACHINE=="yosemite4":
    MODEL="fby35"
else:
    MODEL=MACHINE

# Enter the base directory
#sh.cd "${BASE_DIR}"

# Find the correct drive file, and save its name.  OpenBMC has 3 different
# image formats.  The UBI based one, the standard static.mtd one, and the
# default QEMU basic image (rootfs.ext4).

try:
    DEFAULT_IMAGE_LOC=os.environ['DEFAULT_IMAGE_LOC']
except Exception as e:
    #:-./tmp/deploy/images/}"
    DEFAULT_IMAGE_LOC="./tmp/deploy/images/"

IMAGEPATH=f"{DEFAULT_IMAGE_LOC}/{MACHINE}/"
p=Path(IMAGEPATH)

l=list(p.glob(f"obmc-phosphor-image-{MACHINE}-*.*.mtd"))
print(l)

# Directory symbolic link structure:
#./build-yosemite4/tmp/deploy/images/yosemite4/flash-yosemite4 -> obmc-phosphor-image-yosemite4-20240509200304.static.mtd
#./build-yosemite4/tmp/deploy/images/yosemite4/obmc-phosphor-image-yosemite4-20240509200304.static.mtd
if l:
    head, tail = os.path.split(l[0])
    DRIVE=str(tail)
    print(tail)
else:
    sys.exit("{DEFAULT_IMAGE_LOC}/qemuarm case not implemented")
#    # shellcheck disable=SC2010
#    DRIVE=$(ls f"{DEFAULT_IMAGE_LOC}/qemuarm", "| grep rootfs.ext4")
print(f"DRIVE={DRIVE}")

# Copy the drive file off to /tmp so that QEMU does not write anything back
# to the drive file and make it unusable for future QEMU runs.
TMP_DRIVE_PATH=str(sh.mktemp(f"/tmp/{DRIVE}-XXXXX")).rstrip()

if MACHINE == DEFAULT_MACHINE:
    sh.cp(f"{DEFAULT_IMAGE_LOC}/qemuarm/{DRIVE}", TMP_DRIVE_PATH)
else:
    sh.cp(f"{DEFAULT_IMAGE_LOC}/{MACHINE}/{DRIVE}", TMP_DRIVE_PATH)

# Create docker run args and qemu images
# Grab the container's IP address at the end of the /etc/hosts file
IP=str(sh.awk(["END{print $1}", "/etc/hosts"]))
IP=IP.rstrip()
m=re.match("\d+\.\d+\.\d+\.\d+", IP)

if (m is None):
    IP="127.0.0.1"
print("IP="+IP)

try:
    MACHINE=os.environ['QEMU_WITH_EMMC']
    EMMC=True
except Exception as e:
    EMMC=False

# Patrick's script does this
sh.truncate("-s", "128M", TMP_DRIVE_PATH)

args=[]

if EMMC:
    # Is within /tmp and ok for the container
    IMGFILE_EMMC=str(sh.mktemp()).rstrip()
    sh.truncate("-s", "1G", IMGFILE_EMMC)
    args=["-drive", "if=sd,index=2,format=raw,file={IMGFILE_EMMC}"]

# Docker networking
NET_FORWARDING=f"hostfwd=:{IP}:22-:22,hostfwd=:{IP}:443-:443,hostfwd=tcp:{IP}:80-:80,hostfwd=tcp:{IP}:2200-:2200,hostfwd=udp:{IP}:623-:623,hostfwd=udp:{IP}:664-:664"

# Most system only have one NIC so set this as default
if MACHINE == "tacoma":
    # Tacoma requires us to specify up to four NICs, with the third one being
    # the active device.
    NIC=      ["-net", "nic,model=ftgmac100,netdev=netdev1", "-netdev", "user,id=netdev1"]
    NIC=NIC + ["-net", "nic,model=ftgmac100,netdev=netdev2", "-netdev", "user,id=netdev2"]
    NIC=NIC + ["-net", "nic,model=ftgmac100,netdev=netdev3", "-netdev", f"user,id=netdev3,{NET_FORWARDING}"]
    NIC=NIC + ["-net", "nic,model=ftgmac100,netdev=netdev4", "-netdev", "user,id=netdev4"]
else:
    NIC=      ["-net", "nic,model=ftgmac100,netdev=netdev1", "-netdev", f"user,id=netdev1,{NET_FORWARDING}"]

# From Patrick's scripts
#"-nic"            NIC="nic,model=ftgmac100,netdev=netdev1"
#"-netdev"                                                       NETDEV="user,id=netdev1,"+NET_FORWARDING
# + NIC_OPTIONS=["-net", "nic", "-net", "user,hostfwd=::2222-:22,hostfwd=::8080-:8080,hostname=qemu"]

if MACHINE=="versatilepb":
    # Launch default QEMU using the qemu-system-arm
    args=args+[
        "-device",   "virtio-net,netdev=mynet",
        "-netdev",   f"user,id=mynet,hostfwd=tcp:{IP}:22-:22,hostfwd=tcp:{IP}:443-:443,hostfwd=tcp:{IP}:80-:80,hostfwd=tcp:{IP}:2200-:2200,hostfwd=udp:{IP}:623-:623,hostfwd=udp:{IP}:664-:664",
        "-machine",  "versatilepb",
        "-m",        "256",
        "-drive",    f"file={TMP_DRIVE_PATH},if=virtio,format=raw",
        "-show-cursor",
        "-usb",
        "-usbdevice", "tablet",
        "-device",   "virtio-rng-pci",
        "-serial",   "mon:vc",
        "-serial",   "mon:stdio",
        "-serial",   "null",
        "-kernel",   f"{DEFAULT_IMAGE_LOC}/qemuarm/zImage",
        "-append",   "'root=/dev/vda rw highres=off  console=ttyS0 mem=256M ip=dhcp console=ttyAMA0,115200 console=tty'",
        "-dtb",      f"{DEFAULT_IMAGE_LOC}/qemuarm/zImage-versatile-pb.dtb"
        ]
else:
    args=args+[
        "-machine", f"{MODEL}-bmc",
        "-nographic",
        "-drive",   f"file={TMP_DRIVE_PATH},format=raw,if=mtd",
        ] + NIC

# Launch qemu and leave running
try:
    run=[QEMU_BIN] + args
    print(run)
    ret = subprocess.run(run)
    sys.exit("blah")
except Exception as e:
    print(e)
#finally:
#    print(ret)
print("qemu process exited")

if EMMC:
    rm(IMGFILE_EMMC)

rm(TMP_DRIVE_PATH)
