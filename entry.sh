#!/usr/bin/env bash
# Установка входа каскада: российский сервер принимает телефоны и компьютеры по VLESS + Reality
# и отправляет трафик на заграничные выходы, поставленные этим же install.sh.
# Своего домена, сертификата и сайта не нужно: Reality выдаёт себя за чужой настоящий сайт.
# Обычно запускается из install.sh (вопрос о роли сервера или параметр --entry):
#   curl -fsSL https://raw.githubusercontent.com/zleematana/vpn-setup/main/install.sh | bash -s -- --entry
# Без вопросов:
#   ... | bash -s -- --entry --exit de='vless://...' [--exit nl='vless://...'] [--sni сайт] [ключи...]
# Повторный запуск безопасен: ключи, выходы, ключ Reality и список «напрямую» сохраняются.
set -euo pipefail

RAW=${VPN_SETUP_RAW:-https://raw.githubusercontent.com/zleematana/vpn-setup/main}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)
XDIR=/usr/local/etc/xray
ENVF=$XDIR/entry.env
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

die() { echo; echo "ОШИБКА: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "Запускай от root (или через sudo)."
OS_ID=$(. /etc/os-release 2>/dev/null; echo "${ID:-}")
[ "$OS_ID" = ubuntu ] || [ "$OS_ID" = debian ] || die "Нужна Ubuntu (проверено на 24.04 и 26.04)."
[ -f "$XDIR/client.env" ] && die "Здесь уже стоит выход (есть $XDIR/client.env). Вход ставится на отдельный сервер."

SNI="" KEYS=() EXITS_IN=() SSH_KEY="" NO_PASSWORD=0 ARGS=$#
while [ $# -gt 0 ]; do
    case "$1" in
        --entry) shift ;;
        --sni) SNI=${2:-}; shift 2 || die "После --sni нужен домен." ;;
        --exit) EXITS_IN+=("${2:-}"); shift 2 || die "После --exit нужно имя='ссылка'." ;;
        --ssh-key) SSH_KEY=${2:-}; shift 2 || die "После --ssh-key нужен ключ в кавычках." ;;
        --no-password) NO_PASSWORD=1; shift ;;
        -*) die "Неизвестный параметр $1" ;;
        *) KEYS+=("$1"); shift ;;
    esac
done

ask() { local a=""; read -r -p "$1" a </dev/tty || true; echo "$a"; }
FRESH=1; [ -f "$ENVF" ] && FRESH=0
if [ "$ARGS" -le 1 ] && [ -r /dev/tty ]; then
    echo
    echo "Установка входа каскада (российский сервер)."
    echo
    echo "1. Выходы — заграничные серверы, через которые пойдёт трафик."
    echo "   На каждом выполни: vpn add cascade-ru  и скопируй ссылку «напрямую на IP»."
    [ "$FRESH" = 1 ] || { echo "   Уже подключены:"; ls "$XDIR/exits" 2>/dev/null | sed 's/^/     /'; }
    while :; do
        n=$(ask "   Имя выхода (например de) [Enter — дальше]: ")
        [ -n "$n" ] || break
        l=$(ask "   Ссылка vless:// для «$n»: ")
        [ -n "$l" ] && EXITS_IN+=("$n=$l")
    done
    [ "$FRESH" = 0 ] || [ ${#EXITS_IN[@]} -gt 0 ] || die "Без выхода вход бесполезен. Возьми ссылку на заграничном сервере и запусти снова."
    echo
    echo "2. Сайт для маскировки: вход притворяется им для всех, у кого нет ключа."
    echo "   Нужен российский сайт с TLS 1.3 и HTTP/2, лучше не самый популярный и близкий по сети."
    if [ "$FRESH" = 1 ]; then SNI=$(ask "   Сайт [Enter — подобрать самому]: ")
    else SNI=$(ask "   Сайт [Enter — оставить $(. "$ENVF"; echo "$SNI")]: "); fi
    echo
    echo "3. Ключи: по одному на устройство или человека. Имена латиницей, через пробел."
    if [ "$FRESH" = 1 ]; then read -r -a KEYS <<<"$(ask "   Какие ключи создать [Enter — phone pc]: ")"
    else read -r -a KEYS <<<"$(ask "   Какие ключи добавить [Enter — не добавлять]: ")"; fi
    echo
    echo "4. Вход на сервер по SSH. «да» — только по ключу: надёжнее, но без ключа будет не попасть."
    if [[ "$(ask "   Выключить вход по паролю? [нет/да]: ")" =~ ^(да|Да|ДА|д|Д|yes|Yes|YES|y|Y)$ ]]; then
        if [ -s /root/.ssh/authorized_keys ]; then NO_PASSWORD=1
        else SSH_KEY=$(ask "   Вставь свой публичный ключ (ssh-ed25519 ...): "); fi
    fi
    echo
fi

for k in "${KEYS[@]}"; do
    [[ "$k" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || die "Имя ключа «$k»: только латиница в нижнем регистре, цифры, - и _."
done
for e in "${EXITS_IN[@]}"; do
    [[ "${e%%=*}" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] && [[ "${e#*=}" == vless://* ]] \
        || die "Выход «${e:0:40}…»: нужно имя='vless://...'."
done
if [ -n "$SSH_KEY" ]; then
    [[ "$SSH_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)\ [A-Za-z0-9+/=]+ ]] || die "Это не похоже на публичный SSH-ключ."
fi
if [ "$NO_PASSWORD" = 1 ] && [ -z "$SSH_KEY" ] && [ ! -s /root/.ssh/authorized_keys ]; then
    die "--no-password: на сервере нет ни одного SSH-ключа, после этого на него нельзя было бы зайти."
fi
if ss -Htlnp 'sport = :443' | grep -qv xray; then
    die "Порт 443 уже занят: $(ss -Htlnp 'sport = :443' | head -1). Вход ставится на чистый сервер."
fi

echo "== Пакеты"
apt-get update -qq
apt-get -y -qq -o Dpkg::Options::=--force-confold upgrade >/dev/null
apt-get install -y -qq ufw curl jq qrencode openssl fail2ban unzip python3 >/dev/null
systemctl enable -q --now fail2ban

echo "== Вход на сервер"
if [ -n "$SSH_KEY" ]; then
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
    grep -qxF "$SSH_KEY" /root/.ssh/authorized_keys || echo "$SSH_KEY" >> /root/.ssh/authorized_keys
    NO_PASSWORD=1
fi
if [ "$NO_PASSWORD" = 1 ]; then
    printf '%s\n' "PasswordAuthentication no" "KbdInteractiveAuthentication no" "PermitRootLogin prohibit-password" "PubkeyAuthentication yes" \
        > /etc/ssh/sshd_config.d/00-vpn-setup.conf
    sshd -t && systemctl reload ssh
    echo "   Вход только по SSH-ключу. Вернуть пароль: vpn ssh password on"
else
    echo "   Вход не менялся. Защита от подбора пароля (fail2ban) включена."
fi

echo "== BBR и файрвол (22, 443)"
printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-bbr.conf
sysctl --system >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
for p in 22 443; do ufw allow "$p/tcp" >/dev/null; done
ufw --force enable >/dev/null

echo "== Xray (последний релиз с GitHub, проверка sha256)"
TAG=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/XTLS/Xray-core/releases/latest | sed 's#.*/tag/##')
TMP=$(mktemp -d)
curl -fsSL -o "$TMP/x.zip" "https://github.com/XTLS/Xray-core/releases/download/$TAG/Xray-linux-64.zip"
curl -fsSL -o "$TMP/x.dgst" "https://github.com/XTLS/Xray-core/releases/download/$TAG/Xray-linux-64.zip.dgst"
[ "$(grep -i '^SHA2-256' "$TMP/x.dgst" | awk '{print $NF}')" = "$(sha256sum "$TMP/x.zip" | cut -d' ' -f1)" ] \
    || die "Контрольная сумма Xray не совпала."
unzip -qo "$TMP/x.zip" -d "$TMP/x"
install -m 755 "$TMP/x/xray" /usr/local/bin/xray
mkdir -p /usr/local/share/xray "$XDIR/exits"
install -m 644 "$TMP/x/geoip.dat" "$TMP/x/geosite.dat" /usr/local/share/xray/
rm -rf "$TMP"
echo "   $(/usr/local/bin/xray version | head -1)"

# Сайт для маскировки годится, если отвечает по TLS 1.3 и HTTP/2. Печатает время рукопожатия.
sni_time() { curl -s -o /dev/null --tlsv1.3 --http2 -m 6 -w '%{http_version} %{time_appconnect}' "https://$1/" 2>/dev/null | awk '$1=="2"{print $2; ok=1} END{exit !ok}'; }
if [ -n "$SNI" ]; then
    SNI=$(printf %s "$SNI" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*##')
    sni_time "$SNI" >/dev/null || die "$SNI не отвечает по TLS 1.3 + HTTP/2, для маскировки не подходит. Возьми другой сайт."
elif [ "$FRESH" = 1 ]; then
    echo "== Подбираю сайт для маскировки"
    # Российские сайты из белых списков, не самые громкие: Xray сам не советует брать крупнейшие.
    best="" bt=9
    for d in www.kinopoisk.ru max.ru www.mts.ru www.wildberries.ru www.ozon.ru vk.com ya.ru; do
        t=$(sni_time "$d") || continue
        echo "   $d — ${t} с"
        if awk -v a="$t" -v b="$bt" 'BEGIN{exit !(a<b)}'; then best=$d bt=$t; fi
    done
    [ -n "$best" ] || die "Ни один сайт из списка не ответил. Укажи свой: --sni сайт.ru"
    SNI=$best
    echo "   Беру $SNI. Сменить позже: vpn sni <сайт>"
fi

echo "== Ключ Reality"
mkdir -p "$XDIR"
if [ "$FRESH" = 1 ]; then
    K=$(/usr/local/bin/xray x25519)
    PRIV=$(sed -n 's/^PrivateKey: *//p' <<<"$K")
    PUB=$(sed -n 's/^Password (PublicKey): *//p; s/^Public key: *//p' <<<"$K" | head -1)
    [ -n "$PRIV" ] && [ -n "$PUB" ] || die "Не разобрал вывод xray x25519: $K"
    umask 077
    printf 'LABEL=%s\nSNI=%s\nPRIV=%s\nPUB=%s\nSID=%s\nXPATH=/%s\nDEFAULT_EXIT=\n' \
        "${LABEL:-ru}" "$SNI" "$PRIV" "$PUB" "$(openssl rand -hex 8)" "$(openssl rand -hex 8)" > "$ENVF"
    umask 022
    echo "   Новый ключ создан."
else
    [ -z "$SNI" ] || sed -i "s|^SNI=.*|SNI=$SNI|" "$ENVF"
    echo "   Ключ прежний, ссылки устройств не меняются."
fi

cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config $XDIR/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q xray

echo "== Команда vpn"
if [ -f "$HERE/vpn-entry" ]; then
    install -m 755 "$HERE/vpn-entry" /usr/local/bin/vpn
else
    curl -fsSL -o /usr/local/bin/vpn.new "$RAW/vpn-entry"
    bash -n /usr/local/bin/vpn.new
    install -m 755 /usr/local/bin/vpn.new /usr/local/bin/vpn
    rm -f /usr/local/bin/vpn.new
fi

echo "== Выходы и ключи"
for e in "${EXITS_IN[@]}"; do vpn exit add "${e%%=*}" "${e#*=}"; done
EXISTING=$(awk -F'\t' '$1 !~ /^_/ {print $1}' "$XDIR/keys.tsv" 2>/dev/null || true)
if [ ${#KEYS[@]} -eq 0 ] && [ -z "$EXISTING" ]; then KEYS=(phone pc); fi
for k in "${KEYS[@]}"; do grep -qx "$k" <<<"$EXISTING" || vpn add "$k" >/dev/null; done
vpn apply

echo
echo "== Проверка"
vpn check || true

SHOW=("${KEYS[@]}")
[ ${#SHOW[@]} -gt 0 ] || mapfile -t SHOW <<<"$EXISTING"
for k in "${SHOW[@]}"; do [ -n "$k" ] && vpn link "$k"; done
cat <<EOF

========================================================================
Готово. Вход каскада работает на $(curl -4 -s -m 5 https://api.ipify.org || echo "этом сервере"):443.

Ссылки выше — для Happ или v2RayTun: «+» → «Вставить из буфера» или QR.
Российские сайты идут напрямую отсюда, остальное — через выходы.

  vpn list          ключи и их выходы
  vpn route <ключ> <выход>   через какой выход идёт ключ
  vpn direct add <сайт>      пустить сайт напрямую с российского IP
  vpn abroad add <сайт>      пустить российский сайт через выход
  vpn check         проверить всё целиком
========================================================================
EOF
