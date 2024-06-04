#!/usr/bin/python3

# Sets up the environment inside the container and networking parameters for qemu

#yosemite4 login: root
#Password:
#root@yosemite4:~# logout
#Login timed out after 60 seconds.

import pexpect
import os
import re
import sys
import time
import subprocess
import sh
from sh import rm

try:
    HOME=os.environ['HOME']
except Exception as e:
    print(e)
    sys.exit("HOME not defined")

try:
    QEMU_BIN=os.environ['QEMU_BIN']
except Exception as e:
    print(e)
    sys.exit("QEMU_BIN not defined")

try:
    MACHINE=os.environ['MACHINE']
except Exception as e:
    print(e)
    sys.exit("MACHINE not defined")

# Create docker run args and qemu images
# Grab the container's IP address at the end of the /etc/hosts file
IP=str(sh.awk(["END{print $1}", "/etc/hosts"]))
IP=IP.rstrip()
m=re.match("\d+\.\d+\.\d+\.\d+", IP)
#print("m="+str(m))

print("PID=" + str(os.getpid()))

# else default localhost
if (m is None):
    IP="127.0.0.1"
print("IP="+IP)

# Container HOME
IMGPATH=f"{HOME}/build-{MACHINE}/tmp/deploy/images/{MACHINE}"

# global for clean up
IMGFILE=str(sh.mktemp("--dry-run")).rstrip()
IMGFILE_EMMC=str(sh.mktemp()).rstrip()

p=f"{IMGPATH}/flash-{MACHINE}"

sh.cp(f"{IMGPATH}/flash-{MACHINE}", IMGFILE)
sh.truncate("-s", "128M", IMGFILE)
sh.truncate("-s", "1G", IMGFILE_EMMC)

#Build docker args
NET_FORWARDING=f"hostfwd=:{IP}:22-:22,hostfwd=:{IP}:443-:443,hostfwd=tcp:{IP}:80-:80,hostfwd=tcp:{IP}:2200-:2200,hostfwd=udp:{IP}:623-:623,hostfwd=udp:{IP}:664-:664"

# fby35
## Most system only have one NIC so set this as default
NETDEV="user,id=netdev1,"+NET_FORWARDING
NIC="nic,model=ftgmac100,netdev=netdev1"

# From Patrick's scripts
NIC_OPTIONS=["-net", "nic", "-net", "user,hostfwd=::2222-:22,hostfwd=::8080-:8080,hostname=qemu"]

# special case
if MACHINE=="yosemite4":
    MODEL="fby35"
else:
    MODEL=MACHINE

# Build qemu args
#    "-machine", "help",
args=[
    "-machine", f"{MODEL}-bmc",
    "-drive",   f"file={IMGFILE},format=raw,if=mtd",
    "-net",     NIC,
    "-netdev",  NETDEV,
    "-nographic",
    ] + NIC_OPTIONS

#sys.exit(1)
#    print(" ".join(args))

# Processing images, must be done within the docker container.
# Launch qemu and leave running

try:
    ret = subprocess.run([QEMU_BIN] + args)
except Exception as e:
    print(e)
    print(ret)
finally:
    print(ret)

'''
    if [ "${MACHINE}" = "${DEFAULT_MACHINE}" ]; then
    # Launch default QEMU using the qemu-system-arm
    ${QEMU_BIN} \
        -device virtio-net,netdev=mynet \
        -netdev "user,id=mynet,hostfwd=tcp:${IP}:22-:22,hostfwd=tcp:${IP}:443-:443,hostfwd=tcp:${IP}:80-:80,hostfwd=tcp:${IP}:2200-:2200,hostfwd=udp:${IP}:623-:623,hostfwd=udp:${IP}:664-:664" \
        -machine versatilepb \
        -m 256 \
        -drive file="${TMP_DRIVE_PATH}",if=virtio,format=raw \
        -show-cursor \
        -usb \
        -usbdevice tablet \
        -device virtio-rng-pci \
        -serial mon:vc \
        -serial mon:stdio \
        -serial null \
        -kernel "${DEFAULT_IMAGE_LOC}"/qemuarm/zImage \
        -append 'root=/dev/vda rw highres=off  console=ttyS0 mem=256M ip=dhcp console=ttyAMA0,115200 console=tty'\
        -dtb "${DEFAULT_IMAGE_LOC}"/qemuarm/zImage-versatile-pb.dtb

send_user "OPENBMC-READY\n"
sleep "$env(QEMU_RUN_TIMER)"
send_user "OPENBMC-EXITING\n"
'''
