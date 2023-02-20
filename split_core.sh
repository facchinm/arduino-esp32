#!/bin/bash

# pass vendor on commandline
VENDOR=$1

mkdir ../../esp32_${VENDOR}/esp32
VENDOR_DIR=../../esp32_${VENDOR}/esp32

echo "name=ESP32 Arduino (${VENDOR})" > ${VENDOR_DIR}/platform.txt
cat platform.txt | grep "version=" >> ${VENDOR_DIR}/platform.txt

# Remove fqbns not in $FQBNS list
touch ${VENDOR_DIR}/_boards.txt
# Save all menus (will not be displayed if unused)
cat boards.txt | grep "^menu\." >> ${VENDOR_DIR}/boards.txt
cat boards.txt | grep --ignore-case "${VENDOR}" >> ${VENDOR_DIR}/boards.txt
sed -i "s/build.core=esp32/build.core=esp32:esp32/g" ${VENDOR_DIR}/boards.txt

# really, cat boards.txt for .variant and copy the right folders
cat ${VENDOR_DIR}/boards.txt | grep "\.variant=" | cut -f2 -d"=" | xargs -I{} cp -r variants/{} ${VENDOR_DIR}/variants/

mkdir ${VENDOR_DIR}/tools/
cp -r tools/partitions/ ${VENDOR_DIR}/tools/
cp -r tools/sdk/ ${VENDOR_DIR}/tools/
cp -r tools/gen* ${VENDOR_DIR}/tools/