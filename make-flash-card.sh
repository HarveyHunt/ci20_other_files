#!/bin/bash
#
# Copyright (c) 2013 Imagination Technologies
# Author: Paul Burton <paul.burton@imgtec.com>
#
# Creates an SD card which writes u-boot, a linux kernel & root filesystem to
# the ci20 NAND flash.
#
# Usage:
#   ./make-flash-card.sh /dev/sdX /path/to/rootfs.tar.xz
#

set -e
tmpDir=`mktemp -d`

cleanup()
{
  echo "Cleaning up..."
  [ -z "${sdMount}" ] || sudo umount ${sdMount}
  sync; sync; sync
  rm -rf ${tmpDir}
  trap - EXIT INT TERM
}
trap cleanup EXIT INT TERM

die()
{
  echo "$@" >&2
  exit 1
}

# check device
device="$1"
[ -e "${device}" ] || die "Device '${device}' not found"
grep ${device} /etc/mtab >/dev/null && \
  die "Device '${device}' contains mounted partitions"

# TODO: Autogenerate an image file, using dd and with a timestamp
# check for image file
img="$2"
[ -e "${img}" ] || die "Image file '${img}' not found"

# check root filesystem
rootTar="$3"
[ -e "${rootTar}" ] || die "Root filesystem tarball '${rootTar}' not found"

# default environment
[ ! -z "${CROSS_COMPILE}" ] || export CROSS_COMPILE=mipsel-unknown-linux-gnu-
[ ! -z "${UBOOT_REPO}" ] || UBOOT_REPO="https://github.com/MIPS/CI20_u-boot"
[ ! -z "${UBOOT_BRANCH}" ] || UBOOT_BRANCH="ci20-v2013.10"

if [ -z "${JOBS}" ]; then
  cpuCount=`grep -Ec '^processor' /proc/cpuinfo`
  JOBS=`echo "${cpuCount} * 2" | bc`
fi

# check for tools
which bc >/dev/null || die "No bc in \$PATH"
which fakeroot >/dev/null || die "No fakeroot in \$PATH"
which sfdisk >/dev/null || die "No sfdisk in \$PATH"
which mkfs.ext4 >/dev/null || die "No mkfs.ext4 in \$PATH"
which mkfs.ubifs >/dev/null || die "No mkfs.ubifs in \$PATH"
${CROSS_COMPILE}gcc --version >/dev/null 2>&1 || \
  die "No ${CROSS_COMPILE}gcc, set \$CROSS_COMPILE"
${CROSS_COMPILE}objcopy --version >/dev/null 2>&1 || \
  die "No ${CROSS_COMPILE}objcopy, set \$CROSS_COMPILE"

# partition image file
sudo sfdisk ${img} -L << EOF
2M,,L
EOF

loop_device=$(losetup --show -f -P ${img})

# create ext4 partition
sudo mkfs.ext2 ${loop_device}p1

# mount ext4 partition
sdMount=${tmpDir}/sd_mount
mkdir ${sdMount}
sudo mount ${loop_device}p1 ${sdMount}

# clone u-boot
ubootDir=$tmpDir/u-boot
git clone ${UBOOT_REPO} -b ${UBOOT_BRANCH} --depth 1 $ubootDir

# build & install MMC u-boot
pushd $ubootDir
  make distclean
  make ci20_mmc_config
  make -j${JOBS}
  sudo dd if=spl/u-boot-spl.bin of=${loop_device} obs=512 seek=1
  sudo dd if=u-boot.img of=${loop_device} obs=1K seek=14
popd

# build & copy NAND u-boot
pushd $ubootDir
  make distclean
  make ci20_config
  make -j${JOBS}
  sudo cp -v spl/u-boot-spl.bin ${sdMount}/
  sudo cp -v u-boot.img ${sdMount}/
popd

# build & copy boot UBIFS image
bootPartDir=${tmpDir}/boot_partition
bootImage=${tmpDir}/boot.ubifs

# build root UBIFS image (copied in chunks whilst generating environment)
rootPartDir=${tmpDir}/root_partition
rootImage=${tmpDir}/root.ubifs
mkdir ${rootPartDir}
fakeroot sh -c "tar -xaf ${rootTar} -C ${rootPartDir} && \
  mv ${rootPartDir}/boot ${bootPartDir} && \
  mkfs.ubifs -q -r ${bootPartDir} -m 8192 -e 2080768 -c 128 -o ${bootImage} && \
  mkfs.ubifs -q -r ${rootPartDir} -m 8192 -e 2080768 -c 4196 -o ${rootImage}"
rootImageSize=`stat -c %s ${rootImage}`
rootImageSizeHex=`echo "ibase=10; obase=16; ${rootImageSize}" | bc`

bootImageSize=`stat -c %s ${bootImage}`
bootImageSizeHex=`echo "ibase=10; obase=16; ${bootImageSize}" | bc`
sudo cp -v ${bootImage} ${sdMount}/

# generate (SD/MMC) u-boot environment
envText=${tmpDir}/u-boot-env.txt
envBin=${tmpDir}/u-boot-env.bin
envSize=$((32 * 1024))
bootCmd="mw.l 0xb0010548 0x8000; \
nand erase.chip; \
ext4load mmc 0:1 0x80000000 u-boot-spl.bin; \
writespl 0x80000000 8; \
ext4load mmc 0:1 0x80000000 u-boot.img; \
nand write 0x80000000 0x800000 0x80000; \
mtdparts default; \
ubi part boot; \
ubi create boot; \
ext4load mmc 0:1 0x80000000 boot.ubifs; \
ubi write 0x80000000 boot ${bootImageSizeHex}; \
ubi part system; \
ubi create root; \
run flash_root0"
echo "bootcmd=${bootCmd}" >${envText}

idx=0
remaining=${rootImageSize}
maxBlock=$((128 * 1024 * 1024))
while [ ${remaining} -gt 0 ]; do
  currSize=${remaining}
  [ ${currSize} -le $((128 * 1024 * 1024)) ] || currSize=${maxBlock}
  currSizeHex=`echo "ibase=10; obase=16; ${currSize}" | bc`
  currFile="root.ubifs.${idx}"
  echo "Creating ${currFile}"
  sudo dd if=${rootImage} of=${sdMount}/${currFile} \
    bs=${maxBlock} skip=${idx} count=1
  fullSize=""
  [ ${idx} -gt 0 ] || fullSize="${rootImageSizeHex}"
  flashCmd="ext4load mmc 0:1 0x80000000 ${currFile};"
  flashCmd="${flashCmd} ubi write.part 0x80000000 root ${currSizeHex} ${fullSize};"
  flashCmd="${flashCmd} run flash_root$((${idx} + 1))"
  echo "flash_root${idx}=${flashCmd}" >>${envText}
  idx=$((${idx} + 1))
  remaining=$((${remaining} - ${currSize}))
done

echo "flash_root${idx}=mw.l 0xb0010544 0x8000; echo All done :)" >>${envText}
echo "U-boot environment:"
cat ${envText}
${ubootDir}/tools/mkenvimage -s ${envSize} -o ${envBin} ${envText}
sudo dd if=${envBin} of=${loop_device} obs=1 seek=$((526 * 1024))

# TODO: dd the loop_device's contents to the SD card

echo "SD contents:"
ls -hl ${sdMount}/

echo "Finished, wait for clean up before removing your card!"
