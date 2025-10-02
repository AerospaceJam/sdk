#!/bin/bash

set -e

# --- Configuration ---
IMAGE_URL="https://downloads.raspberrypi.com/raspios_arm64/images/raspios_arm64-2025-05-13/2025-05-13-raspios-bookworm-arm64.img.xz"
IMAGE_FILENAME=$(basename "${IMAGE_URL}")
OUT_ARCHIVE="aerospacejam-sdk-$IMAGE_FILENAME"
OUT_IMG="${OUT_ARCHIVE%.xz}"
DIR_NAME="${IMAGE_FILENAME%.img.xz}"
MOUNT_POINT="/mnt/rpi"
QEMU_ARM=$(which qemu-aarch64-static)
STAGE1_SCRIPT="stage1.sh"
SDK_USERNAME="asj"
SDK_PASSWORD="aerospacejam"

# --- Cleanup Function ---
cleanup() {
    echo "--- Attempting cleanup ---"
    sudo umount "${MOUNT_POINT}/dev/pts" 2>/dev/null || true
    sudo umount "${MOUNT_POINT}/dev" 2>/dev/null || true
    sudo umount "${MOUNT_POINT}/proc" 2>/dev/null || true
    sudo umount "${MOUNT_POINT}/sys" 2>/dev/null || true
    sudo umount "${MOUNT_POINT}/boot" 2>/dev/null || true
    sudo umount "${MOUNT_POINT}" 2>/dev/null || true

    if [ -n "${DIR_NAME}" ] && [ -f "${DIR_NAME}.img" ]; then
        echo "--- Removing loopback device ---"
        sudo kpartx -d "${DIR_NAME}.img" 2>/dev/null || true
    fi
    echo "--- Cleanup complete ---"
}

trap cleanup EXIT

# --- Main Script Logic ---
if [ ! -f "${STAGE1_SCRIPT}" ]; then
    echo "Error: Customization script '${STAGE1_SCRIPT}' not found!"
    exit 1
fi
chmod +x "${STAGE1_SCRIPT}"

# Register QEMU for ARM emulation
reg="echo ':qemu-aarch64-rpi:M::"\
"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:"\
"\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:"\
"${QEMU_ARM}:F' > /proc/sys/fs/binfmt_misc/register"
echo "Registering qemu-aarch64 for binfmt_misc..."
sudo bash -c "${reg}" 2>/dev/null || true

# Download and decompress the image if necessary
if [ ! -f "${IMAGE_FILENAME}" ]; then
    echo "--- Downloading Raspberry Pi OS Image ---"
    wget -O "${IMAGE_FILENAME}" "${IMAGE_URL}"
else
    echo "--- Image already downloaded ---"
fi

if [ ! -f "${DIR_NAME}.img" ]; then
    echo "--- Decompressing Image ---"
    xz -d -k "${IMAGE_FILENAME}"
else
    echo "--- Image already decompressed ---"
fi

echo "--- Expanding image file by 1GB ---"
truncate -s +1G "${DIR_NAME}.img"

echo "--- Resizing root partition ---"
sudo kpartx -d "${DIR_NAME}.img" 2>/dev/null || true
sudo parted --script "${DIR_NAME}.img" resizepart 2 100%

echo "--- Setting up loopback device ---"
# Use -o pipefail to ensure the pipeline fails if kpartx fails
set -o pipefail
LOOP_DEVICE=$(sudo kpartx -av "${DIR_NAME}.img" | awk 'NR==2{print $3}')
set +o pipefail
sleep 2
ROOT_PARTITION="/dev/mapper/${LOOP_DEVICE}"

echo "--- Checking and resizing root filesystem ---"
sudo e2fsck -f "${ROOT_PARTITION}"
sudo resize2fs "${ROOT_PARTITION}"

echo "--- Mounting root partition ---"
sudo mkdir -p "${MOUNT_POINT}"
sudo mount "${ROOT_PARTITION}" "${MOUNT_POINT}"

echo "--- Mounting boot partition ---"
BOOT_LOOP_DEVICE=$(echo "${LOOP_DEVICE}" | sed 's/p2/p1/')
BOOT_PARTITION="/dev/mapper/${BOOT_LOOP_DEVICE}"
sudo mount "${BOOT_PARTITION}" "${MOUNT_POINT}/boot"

echo "--- Copying QEMU static binary ---"
sudo cp /usr/bin/qemu-arm-static "${MOUNT_POINT}/usr/bin/"

echo "--- Copying config files ---"
if [ -d "./root" ]; then
    sudo cp -r ./root/* "${MOUNT_POINT}/"
fi

echo "--- Mounting necessary filesystems ---"
sudo mount --bind /dev "${MOUNT_POINT}/dev"
sudo mount --bind /dev/pts "${MOUNT_POINT}/dev/pts"
sudo mount --bind /proc "${MOUNT_POINT}/proc"
sudo mount --bind /sys "${MOUNT_POINT}/sys"

# echo "Setting user account..."
ENCRYPTED_PASSWORD=$(echo "${SDK_PASSWORD}" | openssl passwd -6 -stdin)
# sudo bash -c "echo '${SDK_USERNAME}:${ENCRYPTED_PASSWORD}' > ${MOUNT_POINT}/boot/userconf.txt"

echo "--- Chrooting and running customization script ---"
sudo cp "${STAGE1_SCRIPT}" "${MOUNT_POINT}/"
sudo chroot "${MOUNT_POINT}" /bin/bash "/${STAGE1_SCRIPT}" "${ENCRYPTED_PASSWORD}"
sudo rm "${MOUNT_POINT}/${STAGE1_SCRIPT}"

sudo cp -r ./example/ "${MOUNT_POINT}/home/${SDK_USERNAME}/teamCode/"
sudo chroot "${MOUNT_POINT}" chown -R "${SDK_USERNAME}:${SDK_USERNAME}" "/home/${SDK_USERNAME}"

mv "${DIR_NAME}.img" $OUT_IMG

echo "--- Created ${OUT_IMG}! Cleanup will now run automatically. ---"