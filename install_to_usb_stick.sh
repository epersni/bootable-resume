#!/usr/bin/env bash

set -e

USB_DEV=/dev/sda
PARTNUMBER_EFI=1
PARTNUMBER_BOOT=2
PARTNUMBER_ROOT=3
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
MOUNT_DIR=${SCRIPT_DIR}/mount
SOURCE_ROOT="${SCRIPT_DIR}/root"
PYRESUME_PLATFORMER_GIT_SRC="git@github.com:epersni/pyresume-platformer.git"

showHelp() {
  cat << EOF  
Usage: $(basename "${BASH_SOURCE[0]}") [options] <command>

Commands:

  install        - Install to --device

Advanced Commands:

  mount          - Mount installed partitions on --device to --mount-dest
  umount         - Unmount all mounted partitions on --mount-dest
  chrootup       - Do all necessary actions to prepare chroot environment
  chrootdown     - Do all necessary action to unprepare chroot environment
  chroot         - Enter interactive chroot environment
  installroot    - Install the --source-root dir to the target

Options:

  -h, --help                   Display this help
  -m, --mountdir <mount-dest>  Destination to use for mount (default: ${MOUNT_DIR})
  -d, --device <device-path>   USB Device (default: ${USB_DEV}) 
  --source-root                Use different source directory to install as root
                               (default: ${SOURCE_ROOT})

EOF
}

# TODO: not hardcode the partition numbering
create_partitions_and_file_systems()
{
  wipefs --all ${USB_DEV}
  (
    echo g # New GPT partition table
    echo n # new partition
    echo 1 # partition number 1
    echo # default - start at beginning of disk 
    echo +512M # EFI boot parttion
    echo n # new partition
    echo 2 # partion number 2
    echo   # default, start immediately after preceding partition
    echo +512M # boot parttion
    echo n # new partition
    echo 3 # partion number 3
    echo   # default, start immediately after preceding partition
    echo   # use the rest to end of disk
    echo t # change partition type
    echo 1 # partition number 1
    echo 1 # partition type number 1 (EFI System)
    echo p # print the in-memory partition table
    echo w # write the partition table
    echo q # and we're done
  ) | fdisk --wipe always ${USB_DEV}
  mkfs.fat -I -F 32 -n EFI ${USB_DEV}${PARTNUMBER_EFI}
  mkfs.ext4 -F -L boot ${USB_DEV}${PARTNUMBER_BOOT}
  mkfs.ext4 -F -L fedora ${USB_DEV}${PARTNUMBER_ROOT}
}

mount_partitions()
{
  umount_partitions
  mkdir --parents "${MOUNT_DIR}/root"
  mount ${USB_DEV}${PARTNUMBER_ROOT} "${MOUNT_DIR}/root"
  
  mkdir --parents "${MOUNT_DIR}/root/boot"
  mount ${USB_DEV}${PARTNUMBER_BOOT} "${MOUNT_DIR}/root/boot"

  mkdir --parents "${MOUNT_DIR}/root/boot/efi"
  mount ${USB_DEV}${PARTNUMBER_EFI} "${MOUNT_DIR}/root/boot/efi"
}

#TODO: run in a trap
umount_partitions()
{
  if mountpoint --quiet "${MOUNT_DIR}/root/boot/efi"; then
    umount --quiet "${MOUNT_DIR}/root/boot/efi"
  fi
  if mountpoint --quiet "${MOUNT_DIR}/root/boot"; then
    umount --quiet "${MOUNT_DIR}/root/boot"
  fi
  if mountpoint --quiet "${MOUNT_DIR}/root/"; then
    umount --quiet --lazy "${MOUNT_DIR}/root/"
  fi
}

after_mount_install_rootfs()
{
  dnf --nodocs --assumeyes --installroot="${MOUNT_DIR}/root" --releasever=36 install system-release
  dnf --nodocs --assumeyes --installroot="${MOUNT_DIR}/root" install @"Fedora Workstation"
  dnf --nodocs --assumeyes --installroot="${MOUNT_DIR}/root" install \
    @base-x \
    grub2 \
    grub2-efi-x64 \
    grub2-efi-x64-modules \
    grub2-tools-extra \
    python3-pygame \
    kernel \
    shim-x64 \
    tar \
    terminus-fonts-grub2 \
    vim
}

prepare_chroot_environment()
{
  mount --bind /dev "${MOUNT_DIR}/root/dev"
  mount --bind /dev/pts  "${MOUNT_DIR}/root/dev/pts" --options gid=5,mode=620
  mount --bind /proc "${MOUNT_DIR}/root/proc"
  mount --bind /sys "${MOUNT_DIR}/root/sys"
}

#TODO do in trap
unprepare_chroot_environment()
{
  umount --quiet --lazy "${MOUNT_DIR}/root/sys"
  umount --quiet --lazy "${MOUNT_DIR}/root/proc"
  umount --quiet --lazy "${MOUNT_DIR}/root/dev/pts"
  umount --quiet --lazy "${MOUNT_DIR}/root/dev"
}

after_mount_prepare_fstab()
{
  local fstab=${MOUNT_DIR}/root/etc/fstab
  cat << EOF > ${fstab}
UUID=$(lsblk --noheadings --output UUID ${USB_DEV}${PARTNUMBER_ROOT}) /         ext4 x-systemd.device-timeout=0 1 1
UUID=$(lsblk --noheadings --output UUID ${USB_DEV}${PARTNUMBER_BOOT}) /boot     ext4 defaults 1 2
UUID=$(lsblk --noheadings --output UUID ${USB_DEV}${PARTNUMBER_EFI}) /boot/efi vfat umask=0077,shortname=winnt 0 2
EOF
}

prepare_resolv_conf()
{
  local target_resolvconf=${MOUNT_DIR}/root/etc/resolv.conf
  rm --force ${target_resolvconf}
  cat /etc/resolv.conf > ${target_resolvconf}
}

unprepare_resolv_conf()
{
  if mountpoint --quiet "${MOUNT_DIR}/root/"; then
    local target_resolvconf=${MOUNT_DIR}/root/etc/resolv.conf
    if [[ -f ${target_resolvconf} ]]; then
      rm -rfv ${target_resolvconf}
    fi
  fi
}

in_target()
{
  chroot ${MOUNT_DIR}/root /bin/bash -c "$@"
}

setup_users_and_password()
{
  local se_linux_mode="$(getenforce)"
  [[ "${se_linux_mode}" == "Enabled" ]] || setenforce 0
  # password is tz21qv..
  in_target 'echo '\''root:$y$j9T$96j7EhhBBT/Vq5/5IciIk0$ANr16oUi3rBPPC7v34Br4wvvBjB.FhCNRxeKgJgQyZ4'\'' | chpasswd --encrypted'
  in_target "useradd demo"
  in_target "echo demo:demo | chpasswd"
  [[ "${se_linux_mode}" == "Enabled" ]] || setenforce 1
}

setup_grub()
{
  local default_kernel="$(in_target 'basename `grubby --default-kernel`')"
  local default_version="$(echo ${default_kernel} | sed 's/vmlinuz-//')"
  local temp_boot_loader_entry_file=$(mktemp)
  cat << EOF > ${temp_boot_loader_entry_file}
title Nicklas Resume Linux
version ${default_version}
linux /${default_kernel}
initrd /initramfs-${default_version}.img
options root=UUID=$(lsblk --noheadings --output UUID ${USB_DEV}${PARTNUMBER_ROOT}) ro  
grub_users \$grub_users
grub_arg --unrestricted
grub_class fedora
EOF
  local boot_entry_filename="nicklas-resume-${default_version}.conf"
  rm -rfv ${MOUNT_DIR}/root/boot/loader/entries/*.conf
  install --mode=644 ${temp_boot_loader_entry_file} \
    ${MOUNT_DIR}/root/boot/loader/entries/${boot_entry_filename}
  rm ${temp_boot_loader_entry_file}
  in_target "grub2-mkconfig --output /boot/efi/EFI/fedora/grub.cfg"
  in_target "cp -vr /usr/lib/grub/x86_64-efi/ /boot/efi/EFI/fedora/"
  in_target "mkdir /boot/efi/EFI/fedora/fonts"
  #bug: https://bugzilla.redhat.com/show_bug.cgi?id=1739762
  in_target "cp -v /usr/share/grub/unicode.pf2 /boot/efi/EFI/fedora/fonts"
  #bug?
  #in_target "cp -vr /usr/lib/grub/x86_64-efi /boot/grub2/"
  # ln -s /boot/grub2 /boot/grub
}

#TODO need to check for cx_freeze (also need in PATH)
add_pyresume_platformer_to_target_files()
{
  local tempdir=$(mktemp --directory)
  local dist_dir=${tempdir}/dist
  local dist_platform="linux-x86_64"
  
  git clone ${PYRESUME_PLATFORMER_GIT_SRC} ${tempdir}
  ( 
    cd ${tempdir}
    python setup.py bdist --dist-dir ${dist_dir} --plat-name ${dist_platform}
  )
  
  fakeroot -- \
    tar xvf \
    `find ${dist_dir} -name pyresume-platformer-*.${dist_platform}.tar.gz` \
    --directory ${MOUNT_DIR}/root/
  
  rm -rf ${tempdir}
}

add_target_files()
{
  local tarfilename="$(mktemp)"
  fakeroot -- tar -czvf ${MOUNT_DIR}/root/${tarfilename} -C ${SOURCE_ROOT} .
  in_target "tar xvf ${tarfilename} -C / && rm ${tarfilename}"
}



options=$(getopt -l "help,mountdir:,device:,source-root:" -o "h,i,m:,d:" -a -- "$@")

# set --:
# If no arguments follow this option, then the positional parameters are unset. Otherwise, the positional parameters 
# are set to the arguments, even if some of them begin with a ‘-’.
eval set -- "$options"

while true
do
case "$1" in
-m|--mountdir) 
    shift;
    MOUNT_DIR=$1
    ;;
-d|--device) 
    shift;
    USB_DEV=$1
    ;;
--source-root)
    shift;
    SOURCE_ROOT=$1
    ;;
-h|--help) 
    showHelp
    exit 0
    ;;
--)
    shift
    break;;
esac
shift
done


if [ "$UID" -ne 0 -o "$EUID" -ne 0 ]; then
  echo "Error: It is necessary to be root for this"
  exit 1
fi

if [[ "$1" == "" ]]; then
  echo "Error: Missing command, see --help"
  exit 1
else
  case "$1" in
    install)
      umount_partitions
      create_partitions_and_file_systems
      mount_partitions
      after_mount_install_rootfs
      after_mount_prepare_fstab
      prepare_resolv_conf
      prepare_chroot_environment
      add_pyresume_platformer_to_target_files
      add_target_files
      setup_users_and_password
      setup_grub
      unprepare_resolv_conf
      unprepare_chroot_environment
      umount_partitions
      ;;
    installroot)
      umount_partitions
      # TODO check if possiblecreate_partitions_and_file_systems
      mount_partitions
      prepare_chroot_environment
      add_pyresume_platformer_to_target_files
      add_target_files
      unprepare_chroot_environment
      umount_partitions
      ;;
    mount)
      mount_partitions
      ;;
    umount)
      umount_partitions
      ;;
    chrootup)
      umount_partitions
      mount_partitions
      prepare_resolv_conf
      prepare_chroot_environment
      ;;
    chrootdown)
      unprepare_resolv_conf
      unprepare_chroot_environment
      umount_partitions
      ;;
    chroot)
      umount_partitions
      mount_partitions
      prepare_resolv_conf
      prepare_chroot_environment
      chroot ${MOUNT_DIR}/root /bin/bash
      unprepare_resolv_conf
      unprepare_chroot_environment
      umount_partitions
      ;;
    *)
      echo "Error: Unrecognized command, see --help"
      exit 1
  esac
fi

