#!/usr/bin/python3
#
# Launch QEMU and verify we can login then sleep for defined amount of time
# before exiting
#
#  Requires following env variables be set:
#   QEMU_RUN_TIMER  Amount of time to run the QEMU instance
#   OBMC_QEMU_SCRIPTS_DIR  Location of scripts

import pexpect
import os
import re
import sys
import time
import subprocess
from sh import awk
from sh import cp
from sh import mktemp
from sh import rm
from sh import truncate

MACHINE="fby35"
#MACHINE="yosemite4"
#DEFAULT_MACHINE="versatilepb"
QEMU_BIN="/home/bhuey/local/builds/qemu/build/qemu-system-arm"
DEFAULT_IMAGE_LOC="/home/bhuey/local/builds/build-fby35/tmp/deploy/images/fby35"

# Grab the container IP address at the end of the /etc/hosts file
IP=str(awk(["END{print $1}", "/etc/hosts"]))
IP=IP.strip()
m=re.match("\d+\.\d+\.\d+\.\d+", IP)
#print("m="+str(m))

print("PID=" + str(os.getpid()))

# Else default localhost
if (m is None):
    IP="127.0.0.1"
print("IP="+IP)

NET_FORWARDING="hostfwd=:"+IP+":22-:22,hostfwd=:"+IP+":443-:443,hostfwd=tcp:"+IP+":80-:80,hostfwd=tcp:"+IP+":2200-:2200,hostfwd=udp:"+IP+":623-:623,hostfwd=udp:"+IP+":664-:664"

# fby35
## Most system only have one NIC so set this as default
NETDEV="user,id=netdev1,"+NET_FORWARDING
NIC="nic,model=ftgmac100,netdev=netdev1"

# From Patrick's scripts
NIC_OPTION=["-net", "nic", "-net", "user,hostfwd=::2222-:22,hostfwd=::8080-:8080,hostname=qemu"]

HOME="/home/bhuey"
#FB_MACHINE="fby35" # will crash
FB_MACHINE="yosemite4"
IMGPATH=HOME+"/local/builds/build-" + FB_MACHINE + "/tmp/deploy/images/" + FB_MACHINE

IMGFILE=str(mktemp("--dry-run"))
IMGFILE_EMMC=str(mktemp())

IMGFILE=IMGFILE.strip()
IMGFILE_EMMC=IMGFILE_EMMC.strip()

cp(IMGPATH+"/flash-" + FB_MACHINE, IMGFILE)
truncate("-s", "128M", IMGFILE)
truncate("-s", "1G", IMGFILE_EMMC)

args=[
    "-machine", MACHINE + "-bmc",
    "-drive",   "file=" + IMGFILE + ",format=raw,if=mtd",
#    "-net",     NIC,
#    "-netdev",  NETDEV,
    "-nographic",
    ] + NIC_OPTION

#args=["--help"]
print(args)
print(" ".join(args))

try:
    print("try\n\n")
    child=pexpect.spawn(QEMU_BIN, args, timeout=None, encoding='utf-8')
    child.logfile = sys.stdout
    child.logfile_send = sys.stdout
    child.delaybeforesend = 0.5

    child.expect('.* login: ')
    print("got login")
    #child.expect('bmc login: ')
    child.sendline('\n')
    child.sendline('\n')
    time.sleep(15)
    child.sendline('root')

    child.expect('Password:')
    print("got password")
    child.sendline('0penBmc')

    child.expect('root@*.:~#')
    print("got prompt")

    print("OPENBMC-READY\n") # signal we are ready
except pexpect.exceptions.TIMEOUT:
    print("pexpect.exception.TIMEOUT")
except Exception as e:
    print("pexpect: exception")
    print("Exception: {}".format(str(e)))
    print("type = {}".format(type(e)))
    print(str(e))
    print("pexpect: exception end")
finally:
    child.close()
    print("child.exitstatus =\t{}".format(child.exitstatus))
    print("child.signalstatus =\t{}".format(child.signalstatus))
    print("try-end\n\n")

#child.expect(pexpect.EOF)
#child.wait()
rm(IMGFILE, IMGFILE_EMMC)

print("OPENBMC-EXITING\n")

"""
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
"""
"""
expect {
  timeout { send_user "\nFailed to boot\n"; exit 1 }
}
send "root\r"
expect {
  timeout { send_user "\nFailed, no login prompt\n"; exit 1 }
}
send "0penBmc\r"
expect {
  timeout { send_user "\nFailed, could not login\n"; exit 1 }
}
send_user "OPENBMC-READY\n"
sleep "$env(QEMU_RUN_TIMER)"
send_user "OPENBMC-EXITING\n"
"""

