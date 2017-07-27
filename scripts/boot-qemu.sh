#!/bin/bash -xe
###############################################################################
# Launch QEMU using the raw commands
#
#  Can be run by specifying the BASE_DIR and QEMU_ARCH when script is called.
#  Additionally this script is automatically called by running the
#  run-robot-qemu-test.sh, it's used to launch the QEMU test container.
#
###############################################################################
#
#  Variables BASE_DIR and QEMU_ARCH are both required but can be optionally
#  input as parameters following the initial script call. Alternatively, they
#  can be input by exporting them or sourcing the script into an environment
#  that has them declared.
#
#  Parameters:
#   parm1:  <optional, QEMU architecture to use >
#            default is ${QEMU_ARCH} - ppc64le-linux or x86_64-linux
#   parm2:  <optional, full path to base directory of qemu binary and images >
#            default is ${HOME}
#
###############################################################################

set -uo pipefail

QEMU_ARCH=${1:-$QEMU_ARCH}
# If QEMU_ARCH is empty exit, it is required to continue
echo "QEMU_ARCH = $QEMU_ARCH"
if [[ -z $QEMU_ARCH ]]; then
    echo "Did not pass in required QEMU arch parameter"
    exit -1
fi

BASE_DIR=${2:-$HOME}
# If BASE_DIR doesn't exist exit, it is required to continue
echo "BASE_DIR = $BASE_DIR"
if [[ ! -d $BASE_DIR ]]; then
    echo "No input directory and HOME not set!"
    exit -1
fi

# Enter the base directory
cd ${BASE_DIR}

# Find the correct drive file, and save its name
DRIVE=$(ls ./tmp/deploy/images/qemuarm | grep rootfs.ext4)

# Launch QEMU using the qemu-system-arm
./tmp/sysroots/${QEMU_ARCH}/usr/bin/qemu-system-arm \
    -redir tcp:443::443 \
    -redir tcp:80::80 \
    -redir tcp:22::22 \
    -machine versatilepb \
    -m 256 \
    -drive file=./tmp/deploy/images/qemuarm/${DRIVE},if=virtio,format=raw \
    -show-cursor \
    -usb \
    -usbdevice tablet \
    -device virtio-rng-pci \
    -serial mon:vc \
    -serial mon:stdio \
    -serial null \
    -kernel ./tmp/deploy/images/qemuarm/zImage \
    -append 'root=/dev/vda rw highres=off  console=ttyS0 mem=256M ip=dhcp console=ttyAMA0,115200 console=tty'\
    -dtb ./tmp/deploy/images/qemuarm/zImage-versatile-pb.dtb
