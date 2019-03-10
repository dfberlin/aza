#!/bin/bash
#
# Automate Arch on ZFS installation for a single disk using systemd boot
#
set -e
POOL=zroot
DEVICE=sda
EFI_END=200 
# Partition the disk
parted --script /dev/${DEVICE} unit MiB mklabel gpt mkpart fat32 1 ${EFI_END} mkpart primary ${EFI_END} 100% set 1 esp on

# Wait for partitions to show up in /dev/disk/by-id
ls /dev/disk/by-id | grep -qe "-part2$"
while [ $? -ne 0 ] ; do
	sleep 1
	ls /dev/disk/by-id | grep -qe "-part2$"
done

# Format the EFI partition
mkfs.vfat -F32 /dev/${DEVICE}1

# Create the ZPOOL
vdev=$(ls -l /dev/disk/by-id/*-part2 | grep ${DEVICE} | awk '{ print $9 }')
zpool create -O compression=lz4 -O mountpoint=none ${POOL} ${vdev}

# Export and re-eimport the pool so the the datasets we are going to create do not clash with existing mountpoints.
zpool export ${POOL}
zpool import -R /mnt ${POOL}

# Create the datasets
zfs create -o mountpoint=none ${POOL}/data
zfs create -o mountpoint=none ${POOL}/ROOT
zfs create -o mountpoint=/ ${POOL}/ROOT/default
zfs create -o mountpoint=/home ${POOL}/data/home
# Set acl type (required?)
zfs set acltype=posixacl ${POOL}/ROOT/default
# Set boot fs (required ?)
#zpool set bootfs=${POOL}/ROOT/default ${POOL}
# We want the default dataset to be mounted now, but not automatically mounted in general.
zfs set canmount=noauto ${POOL}/ROOT/default

# Create the boot / efi mountpoint and mount the efi partition
mkdir /mnt/boot
mount /dev/${DEVICE}1 /mnt/boot

# Start the installation process
# For archzfs (see archzfs.com) Basically importing the key.
pacman-key -r F75D9D76
pacman-key --lsign-key F75D9D76

# Bootstrap target.
pacstrap /mnt base zfs-linux base-devel git

# Make sure the installed system can get updates for ZFS.
echo -e '[archzfs]\nServer = http://archzfs.com/$repo/x86_64' >> /mnt/etc/pacman.conf
arch-chroot /mnt pacman-key -r F75D9D76 && pacman-key --lsign-key F75D9D76

mkdir -p /mnt/etc/zfs
# Home directory for temporary install user
zfs create ${POOL}/data/home/install
arch-chroot /mnt useradd -M -g users -s /bin/bash install
arch-chroot /mnt chown install /home/install

cat > /mnt/home/install/setup.sh << EOF
#!/bin/bash
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc

echo "KEYMAP=de-latin1-nodeadkeys" > /etc/locale.conf
echo "KEYMAP=de-latin1" > /etc/vconsole.conf


su - install -c "git clone https://aur.archlinux.org/mkinitcpio-sd-zfs.git"
su - install -c "cd mkinitcpio-sd-zfs && makepkg"
pacman --noconfirm -U /home/install/mkinitcpio-sd-zfs/mkinitcpio-sd-zfs-*.pkg.tar.xz

sed -i 's/^HOOKS.*$/HOOKS=(base udev autodetect modconf block keyboard systemd sd-zfs filesystems)/' /etc/mkinitcpio.conf
# Build the initramfs once again to have the zfs and the systemd support we just built in it.
mkinitcpio -p linux
bootctl --path=/boot install
EOF

# Execute the sub-script we spit out in the step before
arch-chroot /mnt bash /home/install/setup.sh

# Create an entry for the boot loader
echo "Creating boot loader entry ..."
printf "default arch\ntimeout 3\n" > /mnt/boot/loader/loader.conf
printf "title\tArch Linux\nlinux\t/vmlinuz-linux\ninitrd\tinitramfs-linux.img\noptions\troot=zfs:${POOL}/ROOT/default rw\n" > /mnt/boot/loader/entries/arch.conf

# The install user is no longer required - sorry :(
arch-chroot /mnt userdel install
# The corresponding dataset neither
#zfs destroy ${POOL}/data/home/install

# Prepare for a clean reboot
umount /mnt/boot
zfs umount -a
zpool export ${POOL}
echo "We are done - I hope :)"