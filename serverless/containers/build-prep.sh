#!/bin/bash

set -xeo pipefail

# Give the baker user a place in the file mount
MOUNTPATH=/mnt/cphofer
usermod -aG root baker
chmod 775 $MOUNTPATH
su -c "mkdir -p ${MOUNTPATH}/baker" -l baker
su -c "chmod 700 ${MOUNTPATH}/baker" -l baker
deluser baker root
chmod 755 $MOUNTPATH

echo "Running build scrpt..."
su -c "bash /build.sh" -l baker >> /home/baker/build-log.txt

