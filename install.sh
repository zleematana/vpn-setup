#!/usr/bin/env bash
# Установка VPN-сервера: Xray VLESS + XHTTP за nginx с настоящим сертификатом и сайтом-заглушкой.
# Запуск на чистом Ubuntu 24.04 от root. Без параметров скрипт сам задаст вопросы:
#   curl -fsSL https://raw.githubusercontent.com/zleematana/vpn-setup/main/install.sh | bash
# Или всё сразу, без вопросов:
#   ... | bash -s -- vpn.example.com phone laptop                    (вход по паролю не трогается)
#   ... | bash -s -- vpn.example.com phone --ssh-key "ssh-ed25519 AAAA..."   (добавить ключ и выключить пароль)
#   ... | bash -s -- vpn.example.com --no-password                   (выключить пароль, ключ уже на сервере)
# До запуска A-запись домена должна смотреть на этот сервер (Cloudflare: DNS only, без прокси).
# Повторный запуск безопасен: существующие ключи и секретный путь сохраняются.
set -euo pipefail

RAW=${VPN_SETUP_RAW:-https://raw.githubusercontent.com/zleematana/vpn-setup/main}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)
XDIR=/usr/local/etc/xray
SOCK=/dev/shm/xray-xhttp.sock
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

die() { echo; echo "ОШИБКА: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "Запускай от root (войди на сервер как root)."
# Нужна система с apt: Ubuntu (проверено на 24.04) или Debian. На CentOS, AlmaLinux, Rocky и т. п. не пойдёт.
OS_ID=$(. /etc/os-release 2>/dev/null; echo "${ID:-}")
OS_NAME=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-неизвестная система}")
if ! command -v apt-get >/dev/null 2>&1 || { [ "$OS_ID" != ubuntu ] && [ "$OS_ID" != debian ]; }; then
    die "На сервере стоит $OS_NAME, а скрипт работает только на Ubuntu 24.04.
Переустанови систему в личном кабинете хостера (обычно кнопка «Переустановить ОС»
или «Reinstall»), выбери Ubuntu 24.04 и запусти команду снова.
Внимание: переустановка стирает всё, что есть на сервере, и может сменить пароль root."
fi
[ "$OS_ID" = ubuntu ] || echo "Внимание: скрипт проверен на Ubuntu 24.04, на $OS_NAME может не заработать."

DOMAIN="" KEYS=() SSH_KEY="" NO_PASSWORD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --ssh-key) SSH_KEY=${2:-}; shift 2 || die "После --ssh-key нужен ключ в кавычках." ;;
        --no-password) NO_PASSWORD=1; shift ;;
        -*) die "Неизвестный параметр $1" ;;
        *) if [ -z "$DOMAIN" ]; then DOMAIN=$1; else KEYS+=("$1"); fi; shift ;;
    esac
done

# Вопросы задаются, только если домен не передан в команде. Читаем с терминала:
# сам скрипт приходит через curl | bash, и обычный ввод занят им.
ask() { local a=""; read -r -p "$1" a </dev/tty || true; echo "$a"; }
OLD_DOMAIN=$( [ -f "$XDIR/client.env" ] && (. "$XDIR/client.env"; echo "$DOMAIN") || true )
if [ -z "$DOMAIN" ]; then
    [ -r /dev/tty ] || die "Укажи домен: ... | bash -s -- vpn.example.com"
    echo
    echo "Установка VPN. Нужно ответить на 3 вопроса."
    echo
    while [ -z "$DOMAIN" ]; do
        if [ -n "$OLD_DOMAIN" ]; then
            DOMAIN=$(ask "1. Домен сервера [Enter — оставить $OLD_DOMAIN]: "); DOMAIN=${DOMAIN:-$OLD_DOMAIN}
        else
            DOMAIN=$(ask "1. Домен или поддомен, который смотрит на этот сервер (например vpn.example.com): ")
        fi
    done
    echo
    echo "2. Ключи: по одному на каждое устройство или человека. Имена латиницей, через пробел."
    if [ -n "$OLD_DOMAIN" ]; then
        read -r -a KEYS <<<"$(ask "   Какие ключи добавить [Enter — не добавлять новых]: ")"
    else
        read -r -a KEYS <<<"$(ask "   Какие ключи создать [Enter — phone pc]: ")"
    fi
    echo
    echo "3. Вход на сервер. Сейчас ты заходишь по паролю — так и останется, если ответить «нет»."
    echo "   «да» — вход только по SSH-ключу: надёжнее, но без ключа на сервер будет не попасть."
    if [[ "$(ask "   Выключить вход по паролю? [нет/да]: ")" =~ ^(да|Да|ДА|д|Д|yes|Yes|YES|y|Y)$ ]]; then
        if [ -s /root/.ssh/authorized_keys ]; then
            echo "   На сервере уже есть SSH-ключ ($(grep -c . /root/.ssh/authorized_keys) шт.), пароль будет выключен."
            NO_PASSWORD=1
        else
            SSH_KEY=$(ask "   Вставь свой публичный ключ (строка, начинается с ssh-ed25519 или ssh-rsa): ")
            [ -n "$SSH_KEY" ] || echo "   Ключ не вставлен — вход по паролю остаётся."
        fi
    fi
    echo
fi

DOMAIN=$(echo "$DOMAIN" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*##')
[[ "$DOMAIN" =~ ^([a-z0-9-]+\.)+[a-z]{2,}$ ]] || die "«$DOMAIN» не похож на домен. Нужно что-то вроде vpn.example.com, без http:// и слэшей."
LABEL=${LABEL:-${DOMAIN%%.*}}
for k in "${KEYS[@]}"; do
    [[ "$k" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || die "Имя ключа «$k»: только латиница в нижнем регистре, цифры, - и _, до 32 символов."
done
if [ -n "$SSH_KEY" ]; then
    [[ "$SSH_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)\ [A-Za-z0-9+/=]+ ]] \
        || die "Это не похоже на публичный SSH-ключ. Он начинается с ssh-ed25519 или ssh-rsa и занимает одну строку."
fi
if [ "$NO_PASSWORD" = 1 ] && [ -z "$SSH_KEY" ] && [ ! -s /root/.ssh/authorized_keys ]; then
    die "--no-password: на сервере нет ни одного SSH-ключа, после этого на него нельзя было бы зайти. Передай ключ через --ssh-key."
fi

echo "== Проверяю домен"
MYIP=$(curl -4 -fsS -m 10 https://api.ipify.org || curl -4 -fsS -m 10 https://ifconfig.me)
# Спрашиваем публичный DNS напрямую, чтобы не ждать, пока обновится кэш самого сервера.
resolve() {
    local ip
    ip=$(curl -fsS -m 5 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=$1&type=A" 2>/dev/null \
        | grep -oE '"data":"[0-9.]+"' | head -1 | cut -d'"' -f4 || true)
    [ -n "$ip" ] || ip=$(getent ahostsv4 "$1" | awk 'NR==1{print $1}')
    echo "$ip"
}
DNSIP=$(resolve "$DOMAIN")
if [ "$DNSIP" != "$MYIP" ]; then
    if [ -n "$DNSIP" ]; then echo "   $DOMAIN сейчас указывает на $DNSIP, а у этого сервера адрес $MYIP."; else echo "   $DOMAIN пока никуда не указывает, а у этого сервера адрес $MYIP."; fi
    echo "   Нужна A-запись: $DOMAIN → $MYIP. В Cloudflare — серое облако (DNS only), не оранжевое."
    echo "   Жду, пока запись заработает (до 15 минут). Прервать — Ctrl+C."
    for _ in $(seq 1 45); do
        sleep 20
        DNSIP=$(resolve "$DOMAIN")
        [ "$DNSIP" = "$MYIP" ] && break
        printf '.'
    done
    echo
    [ "$DNSIP" = "$MYIP" ] || die "$DOMAIN так и не указывает на $MYIP (сейчас: ${DNSIP:-никуда}). Проверь A-запись и запусти команду ещё раз. Если там адрес Cloudflare — выключи оранжевое облако."
fi
echo "   $DOMAIN → $MYIP, всё верно."

echo "== Пакеты (пара минут)"
apt-get update -qq
apt-get -y -qq -o Dpkg::Options::=--force-confold upgrade >/dev/null
apt-get install -y -qq nginx certbot ufw unzip curl jq qrencode openssl fail2ban >/dev/null
# fail2ban на 10 минут блокирует адрес после 5 неверных паролей — защита от подбора.
systemctl enable -q --now fail2ban

echo "== Вход на сервер"
if [ -n "$SSH_KEY" ]; then
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
    grep -qxF "$SSH_KEY" /root/.ssh/authorized_keys || echo "$SSH_KEY" >> /root/.ssh/authorized_keys
    NO_PASSWORD=1
fi
if [ "$NO_PASSWORD" = 1 ]; then
    rm -f /etc/ssh/sshd_config.d/00-hardening.conf   # имя из ранних версий скрипта
    cat > /etc/ssh/sshd_config.d/00-vpn-setup.conf <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
EOF
    sshd -t && systemctl reload ssh
    echo "   Вход только по SSH-ключу, пароль выключен. Вернуть: vpn ssh password on"
else
    echo "   Вход не менялся. Защита от подбора пароля (fail2ban) включена."
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
cat <<EOF

========================================================================
Готово. VPN работает на $DOMAIN.

Что дальше:
  1. Поставь на телефон или компьютер приложение Happ (App Store, Google Play)
     или v2rayN (Windows).
  2. Скопируй ссылку vless://... нужного ключа выше и в приложении нажми
     «+» → «Вставить из буфера». Или «+» → «Сканировать QR».
  3. Подключись и открой любой сайт.

Один ключ — одно устройство или один человек. Ключи и ссылки хранятся
на сервере, показать снова: vpn link <имя>. Все команды: vpn
========================================================================
EOF
