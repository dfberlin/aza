# aza
Auto Arch ZFS root
This script aims for a reproducable and quick way to install Arch on a ZFS root filesystem.
It requires an EFI enabled system and a harddisk to work on.

One will still need a ZFS enabled Arch installation ISO file for booting.

But the whole partitioning, bootstrapping, target preparation etc. is done by this script.

WARNING:
Currently there is no safe belt in any way. You may loose all data on the system you try the script on.
It uses whichever device shows up as /dev/sda and will do the installation on it.

