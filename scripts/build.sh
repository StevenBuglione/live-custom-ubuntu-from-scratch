#!/bin/bash
# Robust ISO builder with safe chroot lifecycle and cleanup

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CMD=(setup_host debootstrap run_chroot build_iso)
DATE="$(TZ="UTC" date +"%y%m%d-%H%M%S")"

# ------------------- helpers -------------------

die() { echo "ERROR: $*" >&2; exit 1; }

mount_if_needed() {
  local src="$1" dst="$2" type="${3:-}" opts="${4:-}"
  if ! mountpoint -q "$dst"; then
    if [[ -n "$type" ]]; then
      sudo mount -t "$type" ${opts:+-o "$opts"} "$src" "$dst"
    else
      sudo mount --bind "$src" "$dst"
    fi
  fi
}

umount_if_mounted() {
  local m="$1"
  if mountpoint -q "$m"; then
    sudo umount "$m" || true
  fi
}

# Kill any processes holding files under chroot
kill_chroot_procs() {
  local root="$1"
  # Try a soft pass to show holders
  sudo fuser -vm "$root" || true
  # Then kill (may need a couple passes)
  for _ in {1..3}; do
    sudo fuser -kvm "$root" || true
    sleep 1
  end
}

# ------------------- UI -------------------

function help() {
  if [[ "${1:-}" != "" ]]; then
    echo -e "$1\n"
  else
    echo -e "This script builds a bootable Ubuntu ISO image\n"
  fi
  echo -e "Supported commands : ${CMD[*]}\n"
  echo -e "Syntax: $0 [start_cmd] [-] [end_cmd]"
  echo -e "\trun from start_cmd to end_cmd"
  echo -e "\tif start_cmd is omitted, start from first command"
  echo -e "\tif end_cmd is omitted, end with last command"
  echo -e "\tenter single cmd to run the specific command"
  echo -e "\tenter '-' as only argument to run all commands\n"
  exit 0
}

function find_index() {
  for ((i=0; i<${#CMD[*]}; i++)); do
    if [[ "${CMD[i]}" == "$1" ]]; then
      index=$i
      return
    fi
  done
  help "Command not found : $1"
}

# ------------------- config + checks -------------------

function check_host() {
  local os_ver
  os_ver="$(lsb_release -i 2>/dev/null | grep -E "(Ubuntu|Debian)" || true)"
  if [[ -z "$os_ver" ]]; then
    echo "WARNING : OS is not Debian or Ubuntu and is untested"
  fi
  if [[ $(id -u) -eq 0 ]]; then
    die "This script should not be run as 'root'"
  fi
}

function load_config() {
  if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/config.sh"
  elif [[ -f "$SCRIPT_DIR/default_config.sh" ]]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/default_config.sh"
  else
    die "Unable to find default config file $SCRIPT_DIR/default_config.sh, aborting."
  fi
}

function check_config() {
  local expected_config_version="0.4"
  if [[ "${CONFIG_FILE_VERSION:-}" != "$expected_config_version" ]]; then
    die "Invalid or old config version ${CONFIG_FILE_VERSION:-<unset>}, expected $expected_config_version. Update from default."
  fi
}

# ------------------- chroot lifecycle -------------------

function chroot_enter_setup() {
  # Prepare mountpoints
  sudo mkdir -p chroot/{dev,proc,sys,run,dev/pts}
  # Bind/virtual mounts (idempotent)
  mount_if_needed /dev        chroot/dev
  mount_if_needed /run        chroot/run
  mount_if_needed proc        chroot/proc proc
  mount_if_needed sysfs       chroot/sys  sysfs
  mount_if_needed devpts      chroot/dev/pts devpts "gid=5,mode=620"

  # Prevent services from actually starting inside chroot
  # (return 101 makes maintainer scripts skip service starts)
  sudo tee chroot/usr/sbin/policy-rc.d >/dev/null <<'EOF'
#!/bin/sh
exit 101
EOF
  sudo chmod +x chroot/usr/sbin/policy-rc.d

  # Divert invoke-rc.d to no-op during build
  if ! sudo chroot chroot dpkg-divert --list /usr/sbin/invoke-rc.d >/dev/null 2>&1; then
    sudo chroot chroot dpkg-divert --local --rename --add /usr/sbin/invoke-rc.d || true
    sudo chroot chroot /bin/sh -c 'printf "%s\n" "#!/bin/sh" "exit 0" > /usr/sbin/invoke-rc.d'
    sudo chroot chroot chmod +x /usr/sbin/invoke-rc.d
  fi
}

function chroot_exit_teardown() {
  # Remove service start blockers so the produced image is clean
  sudo rm -f chroot/usr/sbin/policy-rc.d || true
  if sudo chroot chroot test -f /usr/sbin/invoke-rc.d.distrib 2>/dev/null; then
    sudo chroot chroot rm -f /usr/sbin/invoke-rc.d || true
    sudo chroot chroot dpkg-divert --rename --remove /usr/sbin/invoke-rc.d || true
  fi

  # Kill any lingering processes inside chroot
  kill_chroot_procs "chroot"

  # Unmount in reverse dependency order
  umount_if_mounted chroot/dev/pts
  umount_if_mounted chroot/dev
  umount_if_mounted chroot/proc
  umount_if_mounted chroot/sys
  umount_if_mounted chroot/run

  # Last resort: lazy recursive unmount of anything still attached
  if grep -q "$(readlink -f "$SCRIPT_DIR")/chroot" /proc/mounts; then
    # Unmount deepest first
    grep "$(readlink -f "$SCRIPT_DIR")/chroot" /proc/mounts \
      | awk '{print $2}' | sort -r \
      | xargs -r -n1 sudo umount -l || true
  fi
}

# Always attempt teardown even on errors
cleanup() {
  set +e
  chroot_exit_teardown
}
trap cleanup EXIT INT TERM

# ------------------- build steps -------------------

function setup_host() {
  echo "=====> running setup_host ..."
  sudo apt-get update -y
  sudo apt-get install -y debootstrap squashfs-tools xorriso genisoimage rsync fuser
  sudo mkdir -p chroot
}

function debootstrap() {
  echo "=====> running debootstrap ... will take a couple of minutes ..."
  sudo debootstrap --arch=amd64 --variant=minbase "$TARGET_UBUNTU_VERSION" chroot "$TARGET_UBUNTU_MIRROR"
}

function run_chroot() {
  echo "=====> running run_chroot ..."
  chroot_enter_setup

  # Stage build scripts + config into chroot
  sudo install -D -m 0755 "$SCRIPT_DIR/chroot_build.sh" chroot/root/chroot_build.sh
  sudo install -D -m 0644 "$SCRIPT_DIR/default_config.sh" chroot/root/default_config.sh
  if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
    sudo install -D -m 0644 "$SCRIPT_DIR/config.sh" chroot/root/config.sh
  fi

  # Build inside chroot
  sudo chroot chroot env DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-readline}" /root/chroot_build.sh -

  # Cleanup staged files
  sudo rm -f chroot/root/chroot_build.sh chroot/root/default_config.sh chroot/root/config.sh 2>/dev/null || true
}

function build_iso() {
  echo "=====> running build_iso ..."

  # Ensure chroot is fully unmounted before packaging (trap already does this, but be explicit)
  chroot_exit_teardown

  # Move image artifacts out of chroot
  if [[ -d chroot/image ]]; then
    sudo rm -rf "$SCRIPT_DIR/image" || true
    sudo mv chroot/image "$SCRIPT_DIR"/
  fi

  # Compress rootfs
  sudo mksquashfs chroot image/casper/filesystem.squashfs \
    -noappend -no-duplicates -no-recovery \
    -wildcards \
    -comp xz -b 1M -Xdict-size 100% \
    -e "var/cache/apt/archives/*" \
    -e "root/*" \
    -e "root/.*" \
    -e "tmp/*" \
    -e "tmp/.*" \
    -e "swapfile"

  # Write filesystem.size
  sudo du -sx --block-size=1 chroot | cut -f1 | sudo tee image/casper/filesystem.size >/dev/null

  pushd "$SCRIPT_DIR/image" >/dev/null

  sudo xorriso \
    -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -J -J -joliet-long \
    -volid "$TARGET_NAME" \
    -output "$SCRIPT_DIR/$TARGET_NAME.iso" \
    -eltorito-boot isolinux/bios.img \
      -no-emul-boot \
      -boot-load-size 4 \
      -boot-info-table \
      --eltorito-catalog boot.catalog \
      --grub2-boot-info \
      --grub2-mbr ../chroot/usr/lib/grub/i386-pc/boot_hybrid.img \
      -partition_offset 16 \
      --mbr-force-bootable \
    -eltorito-alt-boot \
      -no-emul-boot \
      -e isolinux/efiboot.img \
      -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b isolinux/efiboot.img \
      -appended_part_as_gpt \
      -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
      -m "isolinux/efiboot.img" \
      -m "isolinux/bios.img" \
      -e '--interval:appended_partition_2:::' \
    -exclude isolinux \
    -graft-points \
      "/EFI/boot/bootx64.efi=isolinux/bootx64.efi" \
      "/EFI/boot/mmx64.efi=isolinux/mmx64.efi" \
      "/EFI/boot/grubx64.efi=isolinux/grubx64.efi" \
      "/EFI/ubuntu/grub.cfg=isolinux/grub.cfg" \
      "/isolinux/bios.img=isolinux/bios.img" \
      "/isolinux/efiboot.img=isolinux/efiboot.img" \
      "."

  popd >/dev/null
}

# ------------------- main -------------------

cd "$SCRIPT_DIR"
load_config
check_config
check_host

# Args parsing
if [[ $# -eq 0 || $# -gt 3 ]]; then help; fi
dash_flag=false
start_index=0
end_index=${#CMD[*]}
for ii in "$@"; do
  if [[ "$ii" == "-" ]]; then
    dash_flag=true; continue
  fi
  find_index "$ii"
  if ! $dash_flag; then
    start_index=$index
  else
    end_index=$((index+1))
  fi
done
if ! $dash_flag; then
  end_index=$((start_index + 1))
fi

# Execute selected steps
for ((ii=start_index; ii<end_index; ii++)); do
  "${CMD[ii]}"
done

echo "$0 - Initial build is done!"
