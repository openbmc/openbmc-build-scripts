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
from sh import awk
from sh import cp
from sh import date
from sh import mktemp
from sh import rm
from sh import truncate

try;
    QEMU_BIN=os.environ[[QEMU_BIN])
except Exception as e:
    print(e)

try;
    MACHINE=os.environ[[MACHINE])
except Exception as e:
    print(e)

# Create docker run args and qemu images
def docker_pre_run();
    # Grab the container's IP address at the end of the /etc/hosts file
    IP=str(awk(["END{print $1}", "/etc/hosts"]))
    IP=IP.strip()
    m=re.match("\d+\.\d+\.\d+\.\d+", IP)
    #print("m="+str(m))

    print("PID=" + str(os.getpid()))

    # else default localhost
    if (m is None):
        IP="127.0.0.1"
    print("IP="+IP)

    IMGPATH=HOME+"/local/builds/build-" + MACHINE + "/tmp/deploy/images/" + MACHINE

    # global for clean up
    global IMGFILE=str(mktemp("--dry-run")).strip
    global IMGFILE_EMMC=str(mktemp()).strip

    cp(IMGPATH+"/flash-" + MACHINE, IMGFILE)
    truncate("-s", "128M", IMGFILE)
    truncate("-s", "1G", IMGFILE_EMMC)


    #Build docker args
    NET_FORWARDING="hostfwd=:"+IP+":22-:22,hostfwd=:"+IP+":443-:443,hostfwd=tcp:"+IP+":80-:80,hostfwd=tcp:"+IP+":2200-:2200,hostfwd=udp:"+IP+":623-:623,hostfwd=udp:"+IP+":664-:664"

    # fby35
    ## Most system only have one NIC so set this as default
    NETDEV="user,id=netdev1,"+NET_FORWARDING
    NIC="nic,model=ftgmac100,netdev=netdev1"

    # From Patrick's scripts
    NIC_OPTIONS=["-net", "nic", "-net", "user,hostfwd=::2222-:22,hostfwd=::8080-:8080,hostname=qemu"]

    global args=[
        "-machine", MACHINE + "-bmc",
        "-drive",   "file=" + IMGFILE + ",format=raw,if=mtd",
        "-net",     NIC,
        "-netdev",  NETDEV,
        "-nographic",
        ] + NIC_OPTIONS

#    print(" ".join(args))

# Processing images, must be done within the docker container.
eef docker_qemu_run():
    # Launch qemu and leave running.
    try:
        ret = subprocess.run([QEMU_BIN] + args)
    except:
        print(e)
        print(ret)
    finally:
        print(ret)

docker_pre_run()
docker_qemu_run()

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
