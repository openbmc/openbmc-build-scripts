#!/bin/bash -xe
###############################################################################
# Launch QEMU using the raw commands
#
#  Can be run by specifying the BASE_DIR and QEMU_ARCH when the script is
#  called. Additionally, this script is automatically called by running the
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
# Optional Env Variable:
#
#  QEMU_BIN           = Location of qemu-system-arm binary to use when starting
#                       QEMU relative to upstream workspace.  Default is 
#                       ./tmp/sysroots/${QEMU_ARCH}/usr/bin/qemu-system-arm
#                       which is the default location when doing a bitbake
#                       of obmc-phosphor-image
#
#  MACHINE            = Machine to run test against. witherspoon, palmetto,
#                       romulus, undefined (default).  Default will use the
#                       versatilepb model.
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

# Set the location of the qemu binary relative to BASE_DIR
QEMU_BIN=${QEMU_BIN:-./tmp/sysroots/${QEMU_ARCH}/usr/bin/qemu-system-arm}

MACHINE=${MACHINE:-versatilepb}

# Enter the base directory
cd ${BASE_DIR}

# Find the correct drive file, and save its name.  openbmc has 3 different
# image formats.  The UBI based one, the standard static.mtd one, and the
# default QEMU basic image (rootfs.ext4).

DEFAULT_IMAGE_LOC="./tmp/deploy/images/"
# First look for a UBI image
if [ -d ${DEFAULT_IMAGE_LOC}/${MACHINE} ]; then
    DRIVE=$(ls ${DEFAULT_IMAGE_LOC}/${MACHINE}/ | grep -m 1 obmc-phosphor-image-${MACHINE}.ubi.mtd)

    # If not found then look for a static mdt
    if [ -z ${DRIVE+x} ]; then
        DRIVE=$(ls ${DEFAULT_IMAGE_LOC}/${MACHINE}/ | grep -m 1 obmc-phosphor-image-${MACHINE}.static.mtd)
    fi
fi

# If not found above then use use the default
if [ -z ${DRIVE+x} ]; then
    DRIVE=$(ls ${DEFAULT_IMAGE_LOC}/qemuarm | grep rootfs.ext4)
fi

# If no image to boot from found then exit out
if [ -z ${DRIVE+x} ]; then
	echo "No image found to boot from for machine ${MACHINE}"
	exit -1
fi

# Obtain IP from /etc/hosts if IP is not valid set to localhost
IP=$(awk 'END{print $1}' /etc/hosts)
if [[ "$IP" != *.*.*.* ]]; then
  IP=127.0.0.1
fi

# Launch QEMU using the qemu-system-arm
${QEMU_BIN} \
    -device virtio-net,netdev=mynet \
    -netdev user,id=mynet,hostfwd=tcp:${IP}:22-:22,hostfwd=tcp:${IP}:443-:443,hostfwd=tcp:${IP}:80-:80 \
    -machine versatilepb \
    -m 256 \
    -drive file=${DEFAULT_IMAGE_LOC}/qemuarm/${DRIVE},if=virtio,format=raw \
    -show-cursor \
    -usb \
    -usbdevice tablet \
    -device virtio-rng-pci \
    -serial mon:vc \
    -serial mon:stdio \
    -serial null \
    -kernel ${DEFAULT_IMAGE_LOC}/qemuarm/zImage \
    -append 'root=/dev/vda rw highres=off  console=ttyS0 mem=256M ip=dhcp console=ttyAMA0,115200 console=tty'\
    -dtb ${DEFAULT_IMAGE_LOC}/qemuarm/zImage-versatile-pb.dtb
