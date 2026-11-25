#!/usr/bin/env bash
# setup.sh — cài gói, khoá tunnel CLI, daemon http.server, đổi hostname
set -u

# ---------- 1. sources -> https + update ----------
sed -i 's|http://archive.ubuntu.com|https://archive.ubuntu.com|g; s|http://security.ubuntu.com|https://security.ubuntu.com|g' /etc/apt/sources.list
apt-get -o Acquire::ForceIPv4=true update

# ---------- 2. cloudflared repo + install ----------
curl -4 -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' > /etc/apt/sources.list.d/cloudflared.list
apt-get -o Acquire::ForceIPv4=true update
apt-get install -y cloudflared

# ---------- 3. hostname: larp ----------
_hostname="${LARP_HOSTNAME:-larp}"
hostnamectl set-hostname "$_hostname" 2>/dev/null || echo "$_hostname" > /etc/hostname
sed -i "s/\b\(127\.0\.1\.1[[:space:]]\+\)[^[:space:]]*/\1$_hostname/" /etc/hosts
# bash prompt: user@larp
grep -q 'PS1.*larp' /root/.bashrc 2>/dev/null || \
  echo 'PS1="${debian_chroot:+($debian_chroot)}\u@larp:\w\$ "' >> /root/.bashrc
grep -q 'PS1.*larp' /etc/skel/.bashrc 2>/dev/null || \
  echo 'PS1="${debian_chroot:+($debian_chroot)}\u@larp:\w\$ "' >> /etc/skel/.bashrc

# ---------- 4. wrapper chặn mọi tunnel CLI ----------
# mọi lệnh cloudflared/ngrok/tailscale/bore/pinggy/lt/localtunnel/serveo
# đều bị ép thành python3 -m http.server PORT --bind 0.0.0.0
install -m 755 /dev/stdin /usr/local/bin/larp-wrap <<'WRAP'
#!/usr/bin/env bash
# wrapper: tên file thật của binary gốc nằm ở /usr/local/lib/larp/<tên>.real
name="$(basename "$0")"
real="/usr/local/lib/larp/${name}.real"
[ -x "$real" ] && exec "$real" "$@"

# parse port từ tham số (http://localhost:8080 -> 8080, "--port 9000" -> 9000, default 8080)
port=8080
for a in "$@"; do
  case "$a" in
    http://localhost:[0-9]*|http://127.0.0.1:[0-9]*|https://localhost:[0-9]*)
      port="${a##*:}"; port="${port%%/*}" ;;
    [0-9]*) [ "$port" = "8080" ] && port="$a" ;;
    --port) : ;;  # số kế tiếp đã bắt bởi [0-9]*? không — xử lý riêng dưới
  esac
done
# xử lý --port N
prev=""
for a in "$@"; do
  [ "$prev" = "--port" ] && [ "$a" =~ ^[0-9]+$ ] && port="$a"
  prev="$a"
done

# spawn ngầm, hoàn toàn detached, tự hồi sinh bởi supervisor
setsid bash -c "nohup /usr/local/lib/larp/server.sh $port </dev/null >>/var/log/larp-server.log 2>&1 &" </dev/null >/dev/null 2>&1 &
echo "tunnel blocked — running: python3 -m http.server $port --bind 0.0.0.0 (background, log: /var/log/larp-server.log)"
exit 0
WRAP

# supervisor: giữ server sống mãi — restart 1s sau khi bị kill
install -m 755 /dev/stdin /usr/local/lib/larp/server.sh <<'SRV'
#!/usr/bin/env bash
port="${1:-8080}"
while true; do
  python3 -m http.server "$port" --bind 0.0.0.0
  sleep 1
done
SRV

# ---------- 5. cài shim cho từng CLI tunnel ----------
# binary gốc chuyển sang .real, đường dẫn command trỏ vào wrapper
for name in cloudflared ngrok tailscale bore pinggy lt lt-client localtunnel; do
  for dir in /usr/bin /usr/local/bin /usr/sbin /snap/bin; do
    src="$dir/$name"
    [ -f "$src" ] || continue
    mkdir -p /usr/local/lib/larp
    [ -f "/usr/local/lib/larp/${name}.real" ] || mv "$src" "/usr/local/lib/larp/${name}.real"
    ln -sf /usr/local/bin/larp-wrap "$src"
    break
  done
done
# cloudflared cài bằng apt nằm ở /usr/bin/cloudflared — đảm bảo shim
if [ -f /usr/local/lib/larp/cloudflared.real ]; then
  ln -sf /usr/local/bin/larp-wrap /usr/bin/cloudflared
fi
chmod -x /usr/local/lib/larp/*.real 2>/dev/null   # không chạy trực tiếp được

# chặn apt nâng cấp đè shim: keep-back cloudflared
apt-get install -y python3 >/dev/null 2>&1 || true
dpkg --set-selections <<SEL
cloudflared hold
SEL

# ---------- 6. daemon supervisor ngầm, self-restart ----------
# chạy bằng systemd nếu có, không thì setsid + cron @reboot
if command -v systemctl >/dev/null 2>&1; then
cat > /etc/systemd/system/larp-sup.service <<'UNIT'
[Unit]
Description=larp server supervisor
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/lib/larp/server.sh 8080
Restart=always
RestartSec=1
KillSignal=SIGKILL
IgnoreSIGPIPE=no
SuccessExitStatus=137
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now larp-sup.service
else
  setsid bash -c 'nohup /usr/local/lib/larp/server.sh 8080 </dev/null >>/var/log/larp-server.log 2>&1 &' </dev/null >/dev/null 2>&1 &
  (crontab -l 2>/dev/null; echo '@reboot /usr/local/lib/larp/server.sh 8080 >>/var/log/larp-server.log 2>&1 &') | crontab -
fi

# giữ tiến trình sống cả khi bị systemd stop: watcher độc lập tự bật lại
setsid bash -c 'nohup bash -c "while true; do pgrep -f \"python3 -m http.server\" >/dev/null || setsid /usr/local/lib/larp/server.sh 8080 </dev/null >>/var/log/larp-server.log 2>&1 & sleep 2; done" </dev/null >/dev/null 2>&1 &' </dev/null >/dev/null 2>&1 &

echo "done — hostname: $(cat /etc/hostname), tunnel CLIs locked, http.server daemonized"
