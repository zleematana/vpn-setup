#!/usr/bin/env bash
# Установка VPN-сервера: Xray VLESS + XHTTP за nginx с настоящим сертификатом и сайтом-заглушкой.
# Запуск на чистом Ubuntu 24.04 от root одной командой:
#   curl -fsSL https://raw.githubusercontent.com/zleematana/vpn-setup/main/install.sh | bash -s -- vpn.example.com phone laptop
# Первый аргумент — домен, остальные — имена ключей (по умолчанию: phone pc). В конце печатаются ссылки и QR-коды.
# До запуска A-запись домена должна смотреть на этот сервер (Cloudflare: DNS only, без прокси).
# Повторный запуск безопасен: существующие ключи и секретный путь сохраняются.
set -euo pipefail

DOMAIN=${1:?"Укажи домен: bash install.sh vpn.example.com [ключ1 ключ2 ...]"}
shift
KEYS=("$@")
LABEL=${LABEL:-${DOMAIN%%.*}}
RAW=${VPN_SETUP_RAW:-https://raw.githubusercontent.com/zleematana/vpn-setup/main}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)
XDIR=/usr/local/etc/xray
SOCK=/dev/shm/xray-xhttp.sock
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

[ "$(id -u)" = 0 ] || { echo "Запускай от root." >&2; exit 1; }
for k in "${KEYS[@]}"; do
    [[ "$k" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || { echo "Имя ключа «$k»: латиница в нижнем регистре, цифры, - и _, до 32 символов." >&2; exit 1; }
done

MYIP=$(curl -4 -s https://api.ipify.org)
DNSIP=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}')
[ "$MYIP" = "$DNSIP" ] || { echo "$DOMAIN указывает на ${DNSIP:-ничего}, а сервер — $MYIP. Сначала поправь A-запись." >&2; exit 1; }

echo "== Пакеты"
apt-get update -qq
apt-get -y -qq -o Dpkg::Options::=--force-confold upgrade >/dev/null
apt-get install -y -qq nginx certbot ufw unzip curl jq qrencode openssl >/dev/null

echo "== SSH только по ключу"
if [ -s /root/.ssh/authorized_keys ]; then
    cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
EOF
    rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf
    sshd -t && systemctl reload ssh
else
    echo "   В /root/.ssh/authorized_keys пусто — вход по паролю оставлен, чтобы не потерять доступ."
fi

echo "== BBR и файрвол (22, 80, 443)"
printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-bbr.conf
sysctl --system >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
for p in 22 80 443; do ufw allow "$p/tcp" >/dev/null; done
ufw --force enable >/dev/null

echo "== Xray (последний релиз с GitHub, проверка sha256)"
TAG=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/XTLS/Xray-core/releases/latest | sed 's#.*/tag/##')
TMP=$(mktemp -d)
curl -fsSL -o "$TMP/x.zip" "https://github.com/XTLS/Xray-core/releases/download/$TAG/Xray-linux-64.zip"
curl -fsSL -o "$TMP/x.dgst" "https://github.com/XTLS/Xray-core/releases/download/$TAG/Xray-linux-64.zip.dgst"
[ "$(grep -i '^SHA2-256' "$TMP/x.dgst" | awk '{print $NF}')" = "$(sha256sum "$TMP/x.zip" | cut -d' ' -f1)" ] \
    || { echo "Контрольная сумма Xray не совпала." >&2; exit 1; }
unzip -qo "$TMP/x.zip" -d "$TMP/x"
install -m 755 "$TMP/x/xray" /usr/local/bin/xray
mkdir -p /usr/local/share/xray "$XDIR"
install -m 644 "$TMP/x/geoip.dat" "$TMP/x/geosite.dat" /usr/local/share/xray/
rm -rf "$TMP"
echo "   $(/usr/local/bin/xray version | head -1)"

echo "== Сайт-заглушка и сертификат"
mkdir -p /var/www/acme /var/www/files
# Заглушка у каждого сервера своя (название, цвет, отступы), чтобы серверы с этим скриптом
# нельзя было найти поиском по одинаковой странице. Свой сайт в /var/www/files не перезаписывается.
if [ ! -f /var/www/files/index.html ]; then
    pick() { local a=("$@"); echo "${a[RANDOM % ${#a[@]}]}"; }
    NAME=$(pick "File storage" "Team drive" "Document archive" "Media library" "Cloud files" "Shared folders" "Project space" "Backup portal")
    HINT=$(pick "Sign in to access your files." "Please sign in to continue." "Authorized users only." "Log in with your account.")
    BTN=$(pick "Sign in" "Log in" "Continue")
    COLOR=$(pick "#2d6cdf" "#1f8a70" "#7a4cc2" "#c2513d" "#0f766e" "#3b5bdb" "#b45309" "#475569")
    RAD=$(( 4 + RANDOM % 12 )); PADV=$(( 28 + RANDOM % 20 )); PADH=$(( 32 + RANDOM % 24 )); WIDTH=$(( 320 + RANDOM % 80 ))
    cat > /var/www/files/index.html <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>$NAME</title>
<style>body{font:16px/1.5 system-ui,sans-serif;background:#f6f7f9;color:#222;display:grid;place-items:center;min-height:100vh;margin:0}main{background:#fff;padding:${PADV}px ${PADH}px;border-radius:${RAD}px;box-shadow:0 2px 12px #0001;max-width:${WIDTH}px}h1{font-size:22px;margin:0 0 8px}p{color:#666;margin:0 0 20px}input,button{width:100%;box-sizing:border-box;padding:10px;margin:6px 0;border:1px solid #ccc;border-radius:$(( RAD / 2 ))px;font:inherit}button{background:$COLOR;color:#fff;border:0}</style></head>
<body><main><h1>$NAME</h1><p>$HINT</p><form onsubmit="return false"><input placeholder="Email"><input type="password" placeholder="Password"><button>$BTN</button></form></main></body></html>
EOF
fi
SITE=/etc/nginx/sites-available/$DOMAIN
HTTP_BLOCK="server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    location /.well-known/acme-challenge/ { root /var/www/acme; }
    location / { return 301 https://$DOMAIN\$request_uri; }
}"
# Рабочий сайт с 443 переписывается только в конце: если скрипт упадёт посередине, VPN продолжит работать.
if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    rm -f /etc/nginx/sites-enabled/default
    echo "$HTTP_BLOCK" > "$SITE"
    ln -sf "$SITE" "/etc/nginx/sites-enabled/$DOMAIN"
    nginx -t -q && systemctl reload nginx
    certbot certonly -q --webroot -w /var/www/acme -d "$DOMAIN" --agree-tos \
        --register-unsafely-without-email -n --deploy-hook "systemctl reload nginx"
fi

echo "== Настройки Xray"
if [ -f "$XDIR/client.env" ]; then
    # shellcheck disable=SC1091
    XPATH=$(. "$XDIR/client.env"; echo "$XPATH")
else
    XPATH=/$(openssl rand -hex 8)
fi
umask 077
printf 'DOMAIN=%s\nXPATH=%s\nLABEL=%s\n' "$DOMAIN" "$XPATH" "$LABEL" > "$XDIR/client.env"
umask 022

CLIENTS='[]'
[ -f "$XDIR/config.json" ] && CLIENTS=$(jq '[.inbounds[] | select(.tag=="xhttp-in") | .settings.clients[]]' "$XDIR/config.json")
# Служебный ключ для vpn check: проверка не расходует трафик настоящих ключей.
jq -e 'any(.[]; .email=="_check")' <<<"$CLIENTS" >/dev/null \
    || CLIENTS=$(jq --arg id "$(/usr/local/bin/xray uuid)" '. + [{id:$id, email:"_check"}]' <<<"$CLIENTS")
jq -n --arg sock "$SOCK,0666" --arg path "$XPATH" --argjson clients "$CLIENTS" '{
  log: { loglevel: "warning", access: "none" },
  stats: {},
  api: { tag: "api", listen: "127.0.0.1:10085", services: ["HandlerService", "StatsService"] },
  policy: {
    levels: { "0": { statsUserUplink: true, statsUserDownlink: true, statsUserOnline: true } }
  },
  inbounds: [{
    tag: "xhttp-in",
    listen: $sock,
    protocol: "vless",
    settings: { clients: $clients, decryption: "none" },
    streamSettings: { network: "xhttp", xhttpSettings: { path: $path, mode: "auto" } },
    sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
  }],
  outbounds: [
    { tag: "direct", protocol: "freedom" },
    { tag: "block", protocol: "blackhole" }
  ],
  routing: {
    domainStrategy: "IPIfNonMatch",
    rules: [
      { type: "field", ip: ["geoip:private"], outboundTag: "block" },
      { type: "field", protocol: ["bittorrent"], outboundTag: "block" }
    ]
  }
}' > "$XDIR/config.json.new"
/usr/local/bin/xray run -test -format json -config "$XDIR/config.json.new" >/dev/null
[ -f "$XDIR/config.json" ] && cp -p "$XDIR/config.json" "$XDIR/config.json.bak"
install -m 644 "$XDIR/config.json.new" "$XDIR/config.json"
rm -f "$XDIR/config.json.new"

cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStartPre=/bin/rm -f $SOCK
ExecStart=/usr/local/bin/xray run -config $XDIR/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q xray
systemctl restart xray

echo "== nginx на 443"
{ echo "$HTTP_BLOCK"; cat <<EOF

server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    server_tokens off;

    root /var/www/files;
    index index.html;

    location $XPATH {
        client_max_body_size 0;
        grpc_pass unix:$SOCK;
        grpc_buffer_size 16k;
        grpc_socket_keepalive on;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_set_header Connection "";
        grpc_set_header X-Real-IP \$remote_addr;
    }

    location / { try_files \$uri \$uri/ =404; }
}
EOF
} > "$SITE.new"
[ -f "$SITE" ] && cp -p "$SITE" "$SITE.bak"
mv "$SITE.new" "$SITE"
# Сервер целиком под VPN: остальные сайты (в том числе от прежнего домена) выключаются.
find /etc/nginx/sites-enabled -mindepth 1 ! -name "$DOMAIN" -delete
ln -sf "$SITE" "/etc/nginx/sites-enabled/$DOMAIN"
if ! nginx -t -q; then
    [ -f "$SITE.bak" ] && mv "$SITE.bak" "$SITE"
    echo "Новый конфиг nginx не прошёл проверку, вернул прежний." >&2; exit 1
fi
systemctl reload nginx

echo "== Команда vpn"
if [ -f "$HERE/vpn" ]; then
    install -m 755 "$HERE/vpn" /usr/local/bin/vpn
else
    curl -fsSL -o /usr/local/bin/vpn.new "$RAW/vpn"
    bash -n /usr/local/bin/vpn.new
    install -m 755 /usr/local/bin/vpn.new /usr/local/bin/vpn
    rm -f /usr/local/bin/vpn.new
fi

# Ключи: на новом сервере по умолчанию phone и pc, при повторном запуске — только явно названные новые.
EXISTING=$(jq -r '.inbounds[] | select(.tag=="xhttp-in") | .settings.clients[].email | select(startswith("_") | not)' "$XDIR/config.json")
if [ ${#KEYS[@]} -eq 0 ] && [ -z "$EXISTING" ]; then KEYS=(phone pc); fi
for k in "${KEYS[@]}"; do
    grep -qx "$k" <<<"$EXISTING" || vpn add "$k" >/dev/null
done

echo
echo "== Проверка"
vpn check || true

SHOW=("${KEYS[@]}")
[ ${#SHOW[@]} -gt 0 ] || mapfile -t SHOW <<<"$EXISTING"
for k in "${SHOW[@]}"; do
    [ -n "$k" ] || continue
    echo; echo "===== Ключ «$k» ====="
    vpn link "$k"
done
echo
echo "Готово. Управление: vpn list | vpn add <имя> | vpn del <имя> | vpn link <имя> | vpn check"
