#!/bin/bash
set -e

###############################################################################
# CONFIGURATION
###############################################################################
RELEASE="jammy"        # Ubuntu 22.04
ARCH="amd64"
IMAGE_NAME="ubuntu2204"
IMAGE_SIZE="1G"        # 1GB disk → QCOW2 ~450–550 MB

WORKDIR="${PWD}/${IMAGE_NAME}"
ROOTFS="${WORKDIR}/rootfs"
DISK="${WORKDIR}/${IMAGE_NAME}.img"
QCOW="${WORKDIR}/${IMAGE_NAME}.qcow2"

mkdir -p "${WORKDIR}" "${ROOTFS}"

###############################################################################
# HOST REQUIREMENTS
###############################################################################
echo "[1] Installing host packages..."
apt-get update -y
apt-get install -y \
  debootstrap \
  qemu-utils \
  grub-pc-bin \
  cloud-init \
  initramfs-tools \
  udev \
  linux-image-virtual \
  dosfstools \
  gdisk

###############################################################################
# STEP 1 — CREATE MINIMAL ROOTFS
###############################################################################
echo "[2] Running debootstrap (minbase)…"
debootstrap \
  --variant=minbase \
  --no-check-gpg \
  --arch=${ARCH} \
  ${RELEASE} \
  "${ROOTFS}" \
  http://archive.ubuntu.com/ubuntu/

###############################################################################
# STEP 2 — CREATE RAW DISK
###############################################################################
echo "[3] Creating raw disk (${IMAGE_SIZE})…"
dd if=/dev/zero of="${DISK}" bs=1 count=0 seek=${IMAGE_SIZE}

###############################################################################
# STEP 3 — PARTITION DISK
###############################################################################
echo "[4] Partitioning disk…"
parted -s "${DISK}" mklabel msdos
parted -s "${DISK}" mkpart primary ext4 1MiB 100%

###############################################################################
# STEP 4 — LOOP DEVICE
###############################################################################
LOOP=$(losetup --show -f -P "${DISK}")
echo "→ Loop device: ${LOOP}"

###############################################################################
# STEP 5 — FORMAT ROOT PARTITION
###############################################################################
echo "[5] Formatting ext4 filesystem..."
mkfs.ext4 -F "${LOOP}p1"

###############################################################################
# STEP 6 — MOUNT ROOTFS
###############################################################################
echo "[6] Mounting filesystem..."
mkdir -p "${WORKDIR}/mnt"
mount "${LOOP}p1" "${WORKDIR}/mnt"

echo "[7] Copying rootfs…"
cp -a "${ROOTFS}/." "${WORKDIR}/mnt/"

###############################################################################
# STEP 7 — BASIC SYSTEM CONFIG
###############################################################################
echo "[8] Configuring fstab & hostname…"
echo "/dev/sda1 / ext4 defaults 0 1" > "${WORKDIR}/mnt/etc/fstab"
echo "ubuntu" > "${WORKDIR}/mnt/etc/hostname"

###############################################################################
# STEP 8 — BIND MOUNTS FOR CHROOT
###############################################################################
echo "[9] Preparing chroot environment…"
mount --bind /dev  "${WORKDIR}/mnt/dev"
mount --bind /proc "${WORKDIR}/mnt/proc"
mount --bind /sys  "${WORKDIR}/mnt/sys"
mount --bind /run  "${WORKDIR}/mnt/run"

###############################################################################
# STEP 9 — INSTALL MINIMAL SYSTEM
###############################################################################
echo "[10] Installing minimal packages…"

chroot "${WORKDIR}/mnt" bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update -y

# Minimal runtime
apt-get install -y udev initramfs-tools

# Lightweight kernel
apt-get install -y linux-image-virtual

# SSH server
apt-get install -y openssh-server wget iproute2 net-tools dnsutils vim iputils-ping
systemctl enable ssh || true

# Cloud-init basics
apt-get install -y cloud-init cloud-initramfs-growroot sudo

# GRUB bootloader
apt-get install -y grub-pc grub-pc-bin

apt-get clean
rm -rf /var/lib/apt/lists/*
"

###############################################################################
# CLOUD-INIT CONFIGURATION
###############################################################################
echo "[11] Writing cloud-init configuration…"

cat > "${WORKDIR}/mnt/etc/cloud/cloud.cfg.d/90-default-user.cfg" << EOF
system_info:
  default_user:
    name: ubuntu
    lock_passwd: false
    gecos: Ubuntu
    groups: [adm, sudo]
    shell: /bin/bash

ssh_pwauth: true

chpasswd:
  list: |
    ubuntu:master
    root:master
  expire: False

disable_root: false
EOF

# Remove old cloud-init state
rm -rf "${WORKDIR}/mnt/var/lib/cloud/*"

###############################################################################
# SSH CONFIG (PASSWORD LOGIN ENABLED)
###############################################################################
echo "[12] Configuring SSH password authentication…"
chroot "${WORKDIR}/mnt" bash -c "
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
rm -fv /root/.ssh/authorized_keys
touch /root/.hushlogin
"

###############################################################################
# STEP 10 — INSTALL GRUB
###############################################################################
echo "[13] Installing GRUB bootloader…"

chroot "${WORKDIR}/mnt" bash -c "
echo 'GRUB_CMDLINE_LINUX_DEFAULT=\"console=tty1 console=ttyS0\"' >> /etc/default/grub
echo 'GRUB_TERMINAL=\"console serial\"' >> /etc/default/grub
echo 'GRUB_SERIAL_COMMAND=\"serial --speed=115200\"' >> /etc/default/grub
"

chroot "${WORKDIR}/mnt" grub-install --target=i386-pc --recheck "${LOOP}"

chroot "${WORKDIR}/mnt" update-grub || true

###############################################################################
# STEP 11 — MINIMIZE IMAGE
###############################################################################
echo "[14] Minimizing image (removing docs, caches, logs)…"

chroot "${WORKDIR}/mnt" bash -c "
rm -rf /usr/share/doc/*
rm -rf /usr/share/man/*
rm -rf /usr/share/info/*
rm -rf /var/cache/*
rm -rf /var/log/*
rm -rf /tmp/*
"

echo "[15] Zero-filling free space for better compression…"
chroot "${WORKDIR}/mnt" bash -c "
dd if=/dev/zero of=/EMPTY bs=1M || true
rm -f /EMPTY
"

###############################################################################
# STEP 12 — CLEANUP MOUNTS
###############################################################################
echo "[16] Cleaning up…"

umount "${WORKDIR}/mnt/dev" || true
umount "${WORKDIR}/mnt/proc" || true
umount "${WORKDIR}/mnt/sys" || true
umount "${WORKDIR}/mnt/run" || true
umount "${WORKDIR}/mnt" || true
losetup -d "${LOOP}"

###############################################################################
# STEP 13 — CONVERT TO QCOW2 (COMPRESSED)
###############################################################################
echo "[17] Converting to QCOW2 (compressed)…"
qemu-img convert -c -O qcow2 "${DISK}" "${QCOW}"

echo
echo "=============================================================="
echo "✔ IMAGE BUILD COMPLETE"
echo "RAW IMAGE : ${DISK}"
echo "QCOW2     : ${QCOW}"
echo "SIZE      : $(du -h "${QCOW}" | cut -f1)"
echo "=============================================================="
echo
echo "Upload example:"
echo "  openstack image create --disk-format qcow2 --container-format bare --file ${QCOW} ${IMAGE_NAME}"
echo
