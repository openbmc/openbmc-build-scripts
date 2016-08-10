#!/bin/bash -xe
#
# Launch QEMU using the raw commands
#
#  Parameters:
#   parm1:  <optional, QEMU architecture to use >
#            default is ${QEMU_ARCH} - ppc64le-linux or x86_64-linux
#   parm2:  <optional, full path to base directory of qemu binary and images >
#            default is ${HOME}

set -uo pipefail

QEMU_ARCH=${1:-$QEMU_ARCH}
echo "QEMU_ARCH = $QEMU_ARCH"
if [[ -z $QEMU_ARCH ]]; then
    echo "Did not pass in required QEMU arch parameter"
    exit -1
fi

BASE_DIR=${2:-$HOME}
echo "BASE_DIR = $BASE_DIR"
if [[ ! -d $BASE_DIR ]]; then
    echo "No input directory and HOME not set!"
    exit -1
fi

cd ${BASE_DIR}

./tmp/sysroots/${QEMU_ARCH}/usr/bin/qemu-system-arm -nographic -kernel \
    ./tmp/deploy/images/qemuarm/zImage-qemuarm.bin -M versatilepb \
    -drive file=./tmp/deploy/images/qemuarm/obmc-phosphor-image-qemuarm.ext4,format=raw \
    -no-reboot -show-cursor -usb -usbdevice wacom-tablet -no-reboot -m 128 \
    -redir tcp:22::22 -redir tcp:443::443 --append \
    "root=/dev/sda rw console=ttyAMA0,115200 console=tty mem=128M highres=off \
    rootfstype=ext4 console=ttyS0"
