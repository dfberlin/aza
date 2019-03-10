#!/bin/bash
#
# Automate Arch on ZFS installation for a single disk using systemd boot
#
set -e
POOL=zroot
DEVICE=sda
EFI_END=512

ZEDENV_PKGS="python python-setuptools python-click python-pip"

disk_id() {
    # Echo the /dev/disk/by-id entry that matches $1
    # Echo "none" in case no match has been found.
    # Example:
    # disk_id sda1
    local match=none
    local b_dev
    local b_id
    local id
    for id in /dev/disk/by-id/* ; do
        b_id=$(basename ${id})
        b_dev=$(basename $(readlink ${id}))
        [ "$b_dev" = "$1" ] && match=${b_id} && break
    done
    echo $match
}

error() {
	local code=$2
	echo "$0: $1"
	exit ${code:=1}
}

chexec() {
	arch-chroot /mnt $1
}

enable_networking_dhcp_classic_naming() {
	chexec "ln -s /dev/null /etc/udev/rules.d/80-net-setup-link.rules"
	cp /mnt/etc/netctl/examples/ethernet-dhcp /mnt/etc/netctl/eth0-dhcp
	chexec "netctl enable eth0-dhcp"	
}

enable_sshd() {
	chexec "systemctl enable sshd"
}

set_hostname() {
	local hostname=$1
	echo ${hostname:=nohostname} > /mnt/etc/hostname
}

# Make sure the target device does exist.
[ -b "/dev/${DEVICE}" ] || error "/dev/${DEVICE} does not exist on this system."
# Partition the disk
parted --script /dev/${DEVICE} unit MiB mklabel gpt mkpart fat32 1 ${EFI_END} mkpart primary ${EFI_END} 100% set 1 esp on
# Format the EFI partition and make sure that the created partion appears in /dev before proceeding.
while [ ! -b /dev/${DEVICE}1 ] ; do sleep 1 ; done
mkfs.vfat -F32 /dev/${DEVICE}1

# Wait for partition 2 to show up in /dev/disk/by-id
vdev=$(disk_id ${DEVICE}2)
while [ "$vdev" = none ] ; do
	sleep 1
	vdev=$(disk_id ${DEVICE}2)
done

# Create the ZPOOL
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

# We want the default dataset to be mounted now, but not automatically mounted in general.
# This is requried to be able to use boot environments.
zfs set canmount=noauto ${POOL}/ROOT/default

# Create the boot / efi mountpoint and mount the efi partition
mkdir /mnt/boot
mount /dev/${DEVICE}1 /mnt/boot

# Start the installation process
# For archzfs (see archzfs.com) Basically importing the key.
pacman-key -r F75D9D76
pacman-key --lsign-key F75D9D76

# Bootstrap target.
pacstrap /mnt base zfs-linux base-devel git $ZEDENV_PKGS openssh

# Add an fstab entry for the EFI partition.
echo "/dev/disk/by-id/$(disk_id ${DEVICE}1) /boot vfat defaults 0 1" >> /mnt/etc/fstab
# Enable classic interface naming and dhcp for eth0
enable_networking_dhcp_classic_naming
# Set the hostname
set_hostname
# Enable the ssh server. Yes root has no password, but in the default configutration openssh does not allow root logins anyway.
enable_sshd
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

# mkinitcpio-sd-zfs
su - install -c "git clone https://aur.archlinux.org/mkinitcpio-sd-zfs.git"
su - install -c "cd mkinitcpio-sd-zfs && makepkg"
pacman --noconfirm -U /home/install/mkinitcpio-sd-zfs/mkinitcpio-sd-zfs-*.pkg.tar.xz
sed -i 's/^HOOKS.*$/HOOKS=(base udev autodetect modconf block keyboard systemd sd-zfs filesystems)/' /etc/mkinitcpio.conf

# zedenv & dependencies
su - install -c "git clone https://aur.archlinux.org/zedenv.git"
su - install -c "git clone https://aur.archlinux.org/python-pyzfscmds.git"
su - install -c "cd python-pyzfscmds && makepkg"
pacman --noconfirm -U /home/install/python-pyzfscmds/python-pyzfscmds-*.pkg.tar.xz
su - install -c "cd zedenv && makepkg"
pacman --noconfirm -U /home/install/zedenv/zedenv-*.pkg.tar.xz

# Build the initramfs once again to have the zfs and the systemd support we just built in it.
mkinitcpio -p linux
bootctl --path=/boot install

# Enable systemd ZFS related targets
systemctl enable zfs.target
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs-import.target
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