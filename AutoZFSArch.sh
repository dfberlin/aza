#!/bin/bash
#
# Automate Arch on ZFS installation for a single disk using systemd boot
#
set -e
POOL=zroot
DEVICE=vda
EFI_END=512
LTS="-lts"
LTS=""

# Can be dkms or binary
ZFS_KERNEL_MODULES=dkms
ZFS_KERNEL_MODULES=binary

EXTRA_PKGS="base-devel git "	# Required to build AUR packages.
EXTRA_PKGS+="openssh "
EXTRA_PKGS+="netctl "			# The Arch kernel seams to pull this as a dependancy while the LTS kernel does not ...



GPT_MAX_LABEL_LENGTH=72
ZEDENV_PKGS="python python-setuptools python-click python-pip"
BY=by-partlabel

disk_id() {
    # Echo the /dev/disk/$2 entry that matches $1
    # Echo "none" in case no match has been found.
    # Example:
    # disk_id sda1 by-id
	local by=$2
    local match=none
    local b_dev
    local b_id
    local id
    for id in /dev/disk/${by:=by-id}/* ; do
        b_id=$(basename ${id})
        b_dev=$(basename $(readlink ${id}))
        [ "$b_dev" = "$1" ] && match=${b_id} && break
    done
    echo $match
}

cpu_core_count() {
	# Modern systems are usually equipped with more then one cpu core.
	# We can make use of that to speed up building AUR packages.
	grep -E "^processor\s+:\s+[0-9]+$" /proc/cpuinfo | wc -l
}

error() {
	local code=$2
	echo "$0: $1"
	exit ${code:=1}
}

message() {
	echo "$0: $1"
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

#
# Main
#

# Make sure the target device does exist.
[ -b "/dev/${DEVICE}" ] || error "/dev/${DEVICE} does not exist on this system."
# Read the devices serial number, assuming that it is unique.
serial=$(udevadm info --query=all --name=/dev/${DEVICE} | grep ID_SERIAL_SHORT | sed 's/^.*=//')
num=1 # For testing only
# Virtual disks tend to not have a serial number. We use a dummy here.
[ ${#serial} -eq 0 ] && serial="disk-${num}" 
name_part_efi="${serial}-p1" 
name_part_zfs="${serial}-p2"
if [ ${#name_part_efi} -gt $GPT_MAX_LABEL_LENGTH ] ; then
	error "Partiton label ${name_part_efi} is ${#name_part_efi} characters long. The maximum size of a label is ${GPT_MAX_LABEL_LENGTH}."
elif [ ${#name_part_zfs} -gt $GPT_MAX_LABEL_LENGTH ] ; then
	error "Partiton label ${name_part_zfs} is ${#name_part_zfs} characters long. The maximum size of a label is ${GPT_MAX_LABEL_LENGTH}."
fi
# Partition the disk
parted --script /dev/${DEVICE} unit MiB mklabel gpt mkpart fat32 1 ${EFI_END} mkpart primary ${EFI_END} 100% set 1 esp on name 1 ${name_part_efi} name 2 ${name_part_zfs}
# Format the EFI partition and make sure that the created partion appears in /dev before proceeding.

while [ ! -b /dev/${DEVICE}1 ] ; do
    message "/dev/${DEVICE}1 not yet ready. Retrying."
    sleep 1
done
mkfs.vfat -F32 /dev/${DEVICE}1

# Wait up to 10 seconds for partition 2 to show up in /dev/disk/${BY}
vdev=$(disk_id ${DEVICE}2 ${BY})
for count in {1..10} ; do
        [ "$vdev" != "none" ] && break
        message "/dev/disk/${BY} not yet ready. Waiting for it to come up. ($count)"
	sleep 1
	vdev=$(disk_id ${DEVICE}2 ${BY})
done
[ "$vdev" = "none" ] && error "No /dev/disk/${BY} entry found for ${DEVICE}. Giving up." 

# Create the ZPOOL
message "Creating zpool ${POOL}."
zpool create -f -O compression=lz4 -O mountpoint=none -o ashift=12 -R /mnt ${POOL} ${vdev}

# Create the datasets
zfs create -o mountpoint=none ${POOL}/data
zfs create -o mountpoint=none ${POOL}/ROOT
zfs create -o mountpoint=/ ${POOL}/ROOT/default
zfs create -o mountpoint=/home ${POOL}/data/home
# Set acl type (required?)
zfs set acltype=posixacl ${POOL}/ROOT/default
# Set bootfs (required by zedenv)
zpool set bootfs=${POOL}/ROOT/default ${POOL}
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
# To do that, we first remove the linux package from the base group.
# This way we have the choice to use any kernel package we want (lts or non-lts)
# for the base system while skipping the default kernel.
base_stripped=$(pacman -Sg base | sed 's/^base //; /^linux$/d' | tr '\n' ' ')
#pacstrap /mnt base zfs-linux base-devel git $ZEDENV_PKGS openssh
pacstrap /mnt $base_stripped linux${LTS} zfs-linux${LTS} $ZEDENV_PKGS $EXTRA_PKGS
#pacstrap /mnt $base_stripped linux${LTS} base-devel git

# Home directory for temporary install user
zfs create ${POOL}/data/home/install
chexec "useradd -M -g users -s /bin/bash install"
chexec "chown install /home/install"
# The install user may execute sudo without password.
# Required to build packages from AUR.
echo "install ALL=(ALL) NOPASSWD: ALL" > /mnt/etc/sudoers.d/install
# Add an fstab entry for the EFI partition.
echo "/dev/disk/by-id/$(disk_id ${DEVICE}1) /boot vfat defaults 0 1" >> /mnt/etc/fstab
# Enable classic interface naming and dhcp for eth0
enable_networking_dhcp_classic_naming
# Set the hostname
set_hostname
# Enable the ssh server. Yes root has no password, but in the default configutration openssh does not allow root logins anyway.
#enable_sshd

# The repo is only required in case binary zfs related modules have been choosen.
if [ $ZFS_KERNEL_MODULES = "binary" ] ; then
	echo -e '[archzfs]\nServer = http://archzfs.com/$repo/x86_64' >> /mnt/etc/pacman.conf
	chexec "pacman-key -r F75D9D76"
	chexec "pacman-key --lsign-key F75D9D76"
fi

mkdir -p /mnt/etc/zfs


cat > /mnt/home/install/setup.sh << EOF
#!/bin/bash
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc

echo "KEYMAP=de-latin1-nodeadkeys" > /etc/locale.conf
echo "KEYMAP=de-latin1" > /etc/vconsole.conf

# Set the HOOKS wich are relevant to ZFS
sed -i 's/^HOOKS.*$/HOOKS=(base udev autodetect modconf block keyboard systemd sd-zfs filesystems)/' /etc/mkinitcpio.conf

# mkinitcpio-sd-zfs
su - install -c "git clone https://aur.archlinux.org/mkinitcpio-sd-zfs.git"
su - install -c "cd mkinitcpio-sd-zfs && makepkg"
pacman --noconfirm -U /home/install/mkinitcpio-sd-zfs/mkinitcpio-sd-zfs-*.pkg.tar.xz

# zedenv & dependencies
su - install -c "git clone https://aur.archlinux.org/zedenv.git"
su - install -c "git clone https://aur.archlinux.org/python-pyzfscmds.git"
su - install -c "cd python-pyzfscmds && makepkg"
pacman --noconfirm -U /home/install/python-pyzfscmds/python-pyzfscmds-*.pkg.tar.xz
su - install -c "cd zedenv && makepkg"
pacman --noconfirm -U /home/install/zedenv/zedenv-*.pkg.tar.xz

# Build the initramfs once again to have the zfs and the systemd support we just built in it.
# mkinitcpio -p linux
bootctl --path=/boot install

# Enable systemd ZFS related targets
systemctl enable zfs.target
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs-import.target
EOF

# Execute the sub-script we spit out in the step before
chexec "bash /home/install/setup.sh"
# Create an entry for the boot loader
echo "Creating boot loader entry ..."

cat > /mnt/boot/loader/loader.conf << EOF
default arch
timeout 3
EOF

#FIXME: We have to take care of the kernel names (lts / non-lts)
cat > /mnt/boot/loader/entries/arch.conf << EOF
title	Arch Linux
linux	/vmlinuz-linux${LTS}
initrd	/initramfs-linux${LTS}.img
options	root=zfs:${POOL}/ROOT/default rw
EOF

# The install user is no longer required - sorry :(
chexec "userdel install"
# The corresponding dataset neither
#zfs destroy ${POOL}/data/home/install

# Prepare for a clean reboot
umount /mnt/boot
zfs umount -a
zpool export ${POOL}
echo "We are done - I hope :)"
