# Khi TinyCore boot, nhanh tay nhấn Ctrl+C để dừng bootlocal.sh
# Hoặc từ console Ubuntu, sửa file initrd:

# 1. Unpack initrd
cd /tmp
mkdir tc_fix
cd tc_fix
gzip -dc /boot/tinycore/corepure64-v7netfix-stable-bootfix.gz | cpio -idmv

# 2. Sửa bootlocal.sh
vi opt/bootlocal.sh
# Sửa lệnh ip -> ifconfig
# Hoặc comment toàn bộ phần gây lỗi

# 3. Repack initrd
find . | cpio -o -H newc | gzip -c > /boot/tinycore/corepure64-fixed.gz

# 4. Boot với initrd đã sửa
kexec -l /boot/tinycore/vmlinuz64 --initrd=/boot/tinycore/corepure64-fixed.gz --command-line="console=ttyS0 quiet"
kexec -e
Cách 2: Boot TinyCore với initrd gốc (không patch)
bash
# Dùng initrd gốc chưa patch
kexec -l /boot/tinycore/vmlinuz64 --initrd=/boot/tinycore/corepure64.gz --command-line="console=ttyS0 quiet"
kexec -e
Cách 3: Tạo script fix network trước khi boot
bash
cat > /boot/tinycore/fix.sh <<'EOF'
#!/bin/sh
# Fix network
ifconfig eth0 up
ifconfig eth0 10.0.0.2 netmask 255.255.255.0
route add default gw 10.0.0.1

# Tải image thủ công
wget -O /tmp/image.qcow2.gz "https://drive.usercontent.google.com/download?id=..."
gunzip -c /tmp/image.qcow2.gz | qemu-img convert -f qcow2 -O raw /dev/stdin /dev/sdb
sync
reboot -f
EOF

# Inject vào initrd khi repack
Nếu bạn muốn dừng vòng lặp reboot ngay lập tức:
bash
# Từ console Ubuntu, hủy kexec
sudo kexec -u

# Xóa script gây lỗi
sudo rm -f /boot/tinycore/corepure64-v7netfix-stable-bootfix.gz

# Boot bình thường vào Ubuntu
Bạn muốn tôi tạo script sửa lỗi hoàn chỉnh không?

sửa sc hoàn chỉnh
Đây là script đã được sửa hoàn chỉnh để chạy trên TinyCore (BusyBox), thay thế lệnh ip bằng ifconfig:

bash
#!/bin/bash
set -euo pipefail
# =====================================================================
# TinyCore Auto Windows Deployer v8-busybox-fixed
# - Sử dụng ifconfig thay vì ip (tương thích BusyBox)
# - Hỗ trợ QCOW2 image (chuyển đổi sang raw trước khi dd)
# - DHCP thật với udhcpc (default.script)
# - Tải image qua wget, stream gunzip | qemu-img | dd
# - Theo dõi dd qua pidof + /proc/$pid/fdinfo/1 (offset)
# - Chọn đĩa đích an toàn (ưu tiên /dev/sdb)
# - Unmount toàn bộ phân vùng của đĩa đích
# =====================================================================

# === USER CONFIG =====================================================
GZ_LINK="https://drive.usercontent.google.com/download?id=1LnC2hm4wOdDef8pGFOs9iOhQpSi7SePi&export=download&authuser=1&confirm=t&uuid=91b0d866-71a4-406c-a379-21f13917fd85&at=AFYLz4NE3KxXcg0BT1PqbtiItpPS%3A1787580893040"
SWAP_URL="https://raw.githubusercontent.com/lt4c/stuff/refs/heads/main/grubsdbuefiwin.gz"

# === TINYCORE BOOT ARTIFACTS =========================================
TCE_VERSION="14.x"
ARCH="x86_64"
TCE_MIRROR="http://tinycorelinux.net"
BOOT_DIR="/boot/tinycore"
WORKDIR="/tmp/tinycore_initrd"
KERNEL_URL="$TCE_MIRROR/$TCE_VERSION/$ARCH/release/distribution_files/vmlinuz64"
INITRD_URL="$TCE_MIRROR/$TCE_VERSION/$ARCH/release/distribution_files/corepure64.gz"
KERNEL_PATH="$BOOT_DIR/vmlinuz64"
INITRD_PATH="$BOOT_DIR/corepure64.gz"
INITRD_PATCHED="$BOOT_DIR/corepure64-v8-busybox-fixed.gz"
BUSYBOX_URL="https://raw.githubusercontent.com/lt4c/stuff/refs/heads/main/busybox"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
echo 'kexec-tools kexec-tools/load_kexec boolean true' | debconf-set-selections

echo "[1/6] Installing deps..."
apt-get -y -qq update
apt-get -y -qq install wget curl gzip cpio kexec-tools parted gdisk ca-certificates qemu-utils --no-install-recommends

mkdir -p "$BOOT_DIR" "$WORKDIR"

echo "[2/6] Fetch TinyCore kernel/initrd..."
wget -q -O "$KERNEL_PATH" "$KERNEL_URL"
wget -q -O "$INITRD_PATH" "$INITRD_URL"

echo "[3/6] Unpack initrd..."
cd "$WORKDIR"
gzip -dc "$INITRD_PATH" | cpio -idmv

echo "[4/6] Inject bootlocal.sh + tools..."
mkdir -p "$WORKDIR/srv"
echo "pre-boot: initrd patched, waiting TinyCore..." > "$WORKDIR/srv/lab"
wget -q -O "$WORKDIR/srv/busybox" "$BUSYBOX_URL"
chmod +x "$WORKDIR/srv/busybox"

cat > "$WORKDIR/opt/bootlocal.sh" <<'EOS'
#!/bin/sh
IMAGE_URL="__TC_GZ_LINK__"
SWAP_URL="__TC_SWAP_URL__"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

log(){ echo "$1" | tee -a /srv/lab >/dev/null; }

# HTTP heartbeat
[ -d /srv ] || mkdir -p /srv
touch /srv/lab
chmod +x /srv/busybox
/srv/busybox httpd -p 80 -h /srv &
( while true; do date >> /srv/lab; sleep 5; done ) &
log "[BOOT] BusyBox HTTP :80 up (v8-busybox-fixed)"
log "[SYS] $(uname -a)"
log "[SYS] cmdline: $(cat /proc/cmdline 2>/dev/null)"

# Packages (sequential)
for pkg in ca-certificates.tcz openssl.tcz curl.tcz openssh.tcz parted gdisk qemu-img.tcz; do
  su tc -c "tce-load -wi $pkg" >> /srv/lab 2>&1 || log "[PKG] warn: $pkg load nonzero"
done
/usr/local/etc/init.d/openssh start >/dev/null 2>&1 && log "[PKG] SSH started" || true

# Network: kill stale, real DHCP (default.script)
if pidof udhcpc >/dev/null 2>&1; then killall -q udhcpc; sleep 1; fi
FOUND_NIC=""
ALL_IF="$(ls /sys/class/net 2>/dev/null | tr '\n' ' ')"
log "[NET] ifaces: $ALL_IF"

# Định nghĩa hàm wait_for_ip sử dụng ifconfig
wait_for_ip() {
  local nic="$1"
  local max_wait=15
  local count=0
  while [ $count -lt $max_wait ]; do
    if ifconfig "$nic" 2>/dev/null | grep -q 'inet '; then
      return 0
    fi
    count=$((count + 1))
    sleep 1
  done
  return 1
}

# Lấy IP từ ifconfig
get_ip_addr() {
  ifconfig "$1" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d: -f2 | head -n1
}

for nic in $ALL_IF; do
  [ "$nic" = "lo" ] && continue
  case "$nic" in dummy*|tun*|tap*|sit*|veth*|virbr*|br-*|docker*) continue;; esac
  ifconfig "$nic" up 2>/dev/null
  udhcpc -b -R -x hostname:tinycore -p "/var/run/udhcpc-$nic.pid" -i "$nic" >>/srv/lab 2>&1 || true
  if wait_for_ip "$nic"; then
    FOUND_NIC="$nic"
    break
  fi
  log "[NET] No IP on $nic after 15s"
done

if [ -z "$FOUND_NIC" ]; then
  log "[WARN] DHCP failed on all NICs, applying static IP eth0"
  ifconfig eth0 up 2>/dev/null
  ifconfig eth0 10.0.0.2 netmask 255.255.255.0 2>/dev/null
  route add default gw 10.0.0.1 2>/dev/null
  echo "nameserver 1.1.1.1" > /etc/resolv.conf
  FOUND_NIC="eth0"
  log "[NET] Static 10.0.0.2 configured"
else
  IP_ADDR=$(get_ip_addr "$FOUND_NIC")
  log "[NET] IPv4 acquired on $FOUND_NIC: $IP_ADDR"
fi

# Disk detect — ƯU TIÊN /dev/sdb để tránh ghi lên disk đang boot
log "[DISK] Detecting target..."
TARGET=""
for d in /dev/sdb /dev/vdb /dev/nvme1n1 /dev/sda; do
  if [ -b "$d" ]; then
    TARGET="$d"
    break
  fi
done
if [ -z "$TARGET" ]; then
  # Dùng lsblk nếu có, fallback dùng fdisk
  if command -v lsblk >/dev/null 2>&1; then
    TARGET="$(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' | head -n1 | awk '{print "/dev/"$1}')"
  else
    TARGET="$(fdisk -l 2>/dev/null | grep '^Disk /dev/' | head -n1 | awk '{print $2}' | sed 's/://')"
  fi
fi
[ -z "$TARGET" ] && { log "[ERR] No disk. Rebooting in 3s..."; sleep 3; reboot -f; }
log "[DISK] Using: $TARGET"

# Unmount mọi phân vùng của TARGET
for m in $(mount | awk -v t="$TARGET" '$1 ~ t{print $3}'); do
  umount -f "$m" 2>/dev/null || true
done
sync; sleep 3

# Xác định boot-disk (đĩa hiện chứa /boot hoặc root)
BOOTDISK=""
if command -v lsblk >/dev/null 2>&1; then
  BOOTDISK="$(lsblk -no PKNAME "$(readlink -f /dev/root 2>/dev/null || echo /dev/sda)" 2>/dev/null | sed 's#^#/dev/#')"
fi
[ -z "$BOOTDISK" ] && BOOTDISK="/dev/sda"
log "[DISK] Boot-disk guessed: $BOOTDISK"

# Debug redirect chain
log "[IMG] Checking redirect chain..."
wget --no-check-certificate --max-redirect=20 -S --spider "$IMAGE_URL" 2>>/srv/lab >/dev/null || true

# --- STREAM IMAGE ---
log "[IMG] Start streaming: wget -> gunzip -> qemu-img -> dd"
log "[IMG] PIPE: wget -S -O- \"$IMAGE_URL\" | gunzip -c | qemu-img convert -f qcow2 -O raw /dev/stdin /dev/stdout | dd of=\"$TARGET\" bs=4M conv=fsync"

(
  wget --no-check-certificate --header="Accept-Encoding: identity" -S -O- "$IMAGE_URL" 2>>/srv/lab \
  | gunzip -c 2>>/srv/lab \
  | qemu-img convert -f qcow2 -O raw /dev/stdin /dev/stdout 2>>/srv/lab \
  | dd of="$TARGET" bs=4M conv=fsync 2>>/srv/lab
) &
PIPE_PID=$!

# monitor dd progress
i=0
while kill -0 "$PIPE_PID" 2>/dev/null; do
  PID_DD="$(pidof dd 2>/dev/null | awk '{print $1}')"
  if [ -n "$PID_DD" ] && [ -r "/proc/$PID_DD/fdinfo/1" ]; then
    OFFSET="$(awk '/pos:/{print $2}' /proc/$PID_DD/fdinfo/1 2>/dev/null | head -n1)"
    [ -z "$OFFSET" ] && OFFSET=0
    echo "[IMG] Installing... (${i}s, offset=$OFFSET)" >>/srv/lab
  else
    echo "[IMG] Installing... (${i}s)" >>/srv/lab
  fi
  sleep 5; i=$((i+5))
done

wait "$PIPE_PID"
RC=$?
if [ "$RC" -ne 0 ]; then
  log "[ERR] dd/wget pipeline failed (rc=$RC). Dump tail logs."
  tail -n 50 /srv/lab >>/srv/lab
  reboot -f
fi

sync
if command -v partprobe >/dev/null 2>&1; then
  partprobe "$TARGET" 2>/dev/null || true
fi
log "[OK] Image deployed to $TARGET in ${i}s"

# --- BOOTFIX ---
if [ "$BOOTDISK" != "$TARGET" ] && [ -b "$BOOTDISK" ]; then
  log "[BOOTFIX] Applying boot sector from SWAP_URL to $BOOTDISK"
  wget --no-check-certificate -O /tmp/grub.gz "$SWAP_URL" >>/srv/lab 2>&1 || true
  if [ -s /tmp/grub.gz ]; then
    gunzip -c /tmp/grub.gz 2>>/srv/lab | dd of="$BOOTDISK" bs=4M 2>>/srv/lab || true
    sync
    log "[BOOTFIX] MBR/bootsector written to $BOOTDISK"
  else
    log "[BOOTFIX] Failed to download grub.gz"
  fi
else
  log "[BOOTFIX] Skipped (boot-disk == target or boot-disk missing)"
fi

sleep 3
log "[SYS] Rebooting..."
reboot -f
EOS

# Inject runtime vars
sed -i "s#__TC_GZ_LINK__#${GZ_LINK}#g"   "$WORKDIR/opt/bootlocal.sh"
sed -i "s#__TC_SWAP_URL__#${SWAP_URL}#g" "$WORKDIR/opt/bootlocal.sh"
chmod +x "$WORKDIR/opt/bootlocal.sh"

# Ensure autorun
grep -q "/opt/bootlocal.sh" "$WORKDIR/etc/init.d/tc-config" || echo "/opt/bootlocal.sh &" >> "$WORKDIR/etc/init.d/tc-config"

echo "[5/6] Repack initrd..."
find . | cpio -o -H newc | gzip -c > "$INITRD_PATCHED"

echo "[6/6] Kexec TinyCore..."
CMDLINE="console=ttyS0 quiet"
kexec -l "$KERNEL_PATH" --initrd="$INITRD_PATCHED" --command-line="$CMDLINE"
echo "===================================================="
echo "🚀 TinyCore v8-busybox-fixed: ifconfig + qemu-img + dd + bootfix"
echo "===================================================="
sleep 2
kexec -e
