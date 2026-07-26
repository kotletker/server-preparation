#!/usr/bin/env bash
#
# setup-server.sh
#
# 1) rsyslog
# 2) traffic-guard (dotX12/traffic-guard) с antiscanner + government_networks листами
# 3) fallback-сайт (nginx + certbot) на основе шаблона из eGamesAPI/simple-web-templates,
#    домен запрашивается интерактивно и сверяется с внешним IP сервера.
#    При установке сайта можно выбрать обычную версию конфига или версию под CDN
#    (proxy_protocol + backend /api/v4/lop на 127.0.0.1:4443).
#
# После выполнения любого пункта скрипт возвращается в главное меню.
# Пункт 0 — выход из скрипта.
# Останавливается на первой же ошибке любого шага.

set -euo pipefail

# ---------- оформление ----------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[36m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
inf()  { echo -e "${BLUE}[*]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[ОШИБКА]${RESET} $*" >&2; }

trap 'err "Скрипт остановлен из-за ошибки на строке $LINENO. Выполнение прервано."; exit 1' ERR

CURRENT_TMP_DIR=""
cleanup_on_exit() {
  if [[ -n "$CURRENT_TMP_DIR" && -d "$CURRENT_TMP_DIR" ]]; then
    rm -rf "$CURRENT_TMP_DIR"
  fi
}
trap cleanup_on_exit EXIT

if [[ $EUID -ne 0 ]]; then
  err "Запускайте скрипт от root (sudo bash $0)."
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  inf "Установка curl (требуется для дальнейших шагов)"
  apt update
  apt install -y curl
fi

inf "Обновление списка пакетов (apt update)"
apt update

########################################
# 1) rsyslog + traffic-guard
########################################
step_rsyslog() {
  inf "rsyslog: установка"
  apt update
  apt install rsyslog -y
  systemctl enable --now rsyslog
  systemctl restart rsyslog
  ok "rsyslog установлен и запущен"
}

step_traffic_guard() {
  inf "traffic-guard: установка"
  curl -fsSL https://raw.githubusercontent.com/dotX12/traffic-guard/master/install.sh | bash

  traffic-guard full \
    -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list \
    -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list \
    --enable-logging
  ok "traffic-guard установлен и настроен"
}

step_base_setup() {
  inf "Шаг 1: rsyslog + traffic-guard"
  step_rsyslog
  step_traffic_guard
  ok "Шаг 1 завершён: rsyslog и traffic-guard установлены"
}

########################################
# 2) fallback-сайт: домен, nginx, certbot
########################################
step_fallback_site() {
  inf "Шаг 2: настройка fallback-сайта"

  if ! command -v dig >/dev/null 2>&1; then
    apt install -y dnsutils
  fi

  echo "Какую версию конфига сайта установить?"
  echo "  1) обычная (без CDN)"
  echo "  2) под CDN (proxy_protocol + backend /api/v4/lop на 127.0.0.1:4443)"
  read -rp "Выбор [1/2]: " SITE_VERSION
  SITE_VERSION="$(echo -n "$SITE_VERSION" | xargs)"
  case "$SITE_VERSION" in
    1|2) ;;
    *) err "Неизвестный вариант: '$SITE_VERSION' (допустимо 1 или 2)"; exit 1 ;;
  esac

  read -rp "Введите домен сервера (например, example.com): " DOMAIN
  DOMAIN="$(echo -n "$DOMAIN" | xargs)"
  if [[ -z "$DOMAIN" ]]; then
    err "Домен не может быть пустым."
    exit 1
  fi

  SERVER_IP="$(curl -fsS -4 ifconfig.me || true)"
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(curl -fsS -4 icanhazip.com || true)"
  fi
  if [[ -z "$SERVER_IP" ]]; then
    err "Не удалось определить внешний IP сервера."
    exit 1
  fi
  inf "IP сервера: $SERVER_IP"

  DOMAIN_IP="$(dig +short A "$DOMAIN" | tail -n1 || true)"
  if [[ -z "$DOMAIN_IP" ]]; then
    warn "Не удалось получить A-запись для домена $DOMAIN (пусто)."
  fi
  inf "IP домена ($DOMAIN): ${DOMAIN_IP:-<нет ответа>}"

  if [[ "$DOMAIN_IP" == "$SERVER_IP" ]]; then
    ok "Домен указывает на этот сервер. Продолжаем."
  else
    warn "Домен $DOMAIN указывает на IP '${DOMAIN_IP:-<нет ответа>}', а IP этого сервера — $SERVER_IP."
    warn "Это может привести к ошибке при выпуске сертификата Let's Encrypt (домен не резолвится на этот сервер)."
    read -rp "Всё равно продолжить? Введите 'yes' для подтверждения: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
      err "Отменено пользователем из-за несовпадения домена и IP."
      exit 1
    fi
    warn "Продолжаем по подтверждению пользователя, несмотря на несовпадение IP."
  fi

  read -rp "Введите e-mail для регистрации в Let's Encrypt/certbot: " CERT_EMAIL
  CERT_EMAIL="$(echo -n "$CERT_EMAIL" | xargs)"
  if [[ -z "$CERT_EMAIL" ]]; then
    err "E-mail не может быть пустым (нужен для certbot)."
    exit 1
  fi

  WEBROOT="/var/www/${DOMAIN}"
  SITE_CONF="/etc/nginx/sites-available/${DOMAIN}"
  SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}"

  # --- каталог сайта + случайный шаблон (частичный git-checkout, без скачивания всего репозитория ~270 МБ) ---
  inf "Создание $WEBROOT и загрузка случайного шаблона"
  mkdir -p "$WEBROOT"

  if ! command -v git >/dev/null 2>&1; then
    inf "Установка git"
    apt install -y git
  fi

  AVAIL_MB="$(df -Pm /var/tmp | awk 'NR==2 {print $4}')"
  if [[ -n "$AVAIL_MB" && "$AVAIL_MB" -lt 200 ]]; then
    err "Мало свободного места в /var/tmp (${AVAIL_MB} МБ). Освободите место (df -h) и запустите шаг заново."
    exit 1
  fi

  TMP_DIR="$(mktemp -d --tmpdir=/var/tmp)"
  CURRENT_TMP_DIR="$TMP_DIR"

  git clone --quiet --filter=blob:none --sparse --depth 1 \
    https://github.com/eGamesAPI/simple-web-templates.git "$TMP_DIR"

  TEMPLATE_LIST="$(cd "$TMP_DIR" && git ls-tree -d --name-only HEAD | grep -vx "assets")"
  if [[ -z "$TEMPLATE_LIST" ]]; then
    err "Не удалось получить список шаблонов сайта."
    exit 1
  fi

  RANDOM_TEMPLATE_NAME="$(echo "$TEMPLATE_LIST" | shuf -n1)"
  if [[ -z "$RANDOM_TEMPLATE_NAME" ]]; then
    err "Не удалось выбрать шаблон сайта."
    exit 1
  fi
  inf "Выбран шаблон: $RANDOM_TEMPLATE_NAME (скачивается только эта папка, не весь репозиторий)"

  (cd "$TMP_DIR" && git sparse-checkout set "$RANDOM_TEMPLATE_NAME")

  if [[ ! -d "$TMP_DIR/$RANDOM_TEMPLATE_NAME" ]]; then
    err "Папка шаблона не появилась после sparse-checkout."
    exit 1
  fi

  rm -rf "${WEBROOT:?}"/*
  cp -a "$TMP_DIR/$RANDOM_TEMPLATE_NAME"/. "$WEBROOT"/
  rm -rf "$TMP_DIR"
  CURRENT_TMP_DIR=""
  ok "Шаблон установлен в $WEBROOT"

  # --- nginx: базовый HTTP-блок (нужен для certbot) ---
  inf "Установка nginx"
  apt install nginx -y

  inf "Настройка HTTP-конфига (порт 80) для выпуска сертификата"
  cat > "$SITE_CONF" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
    }

    location / {
        return 404;
    }
}
EOF

  ln -sf "$SITE_CONF" "$SITE_LINK"
  nginx -t
  systemctl restart nginx
  ok "nginx настроен для проверки домена (HTTP)"

  # --- certbot ---
  inf "Установка certbot и выпуск сертификата"
  apt install -y certbot
  certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" --agree-tos -m "$CERT_EMAIL" --non-interactive
  ok "Сертификат для $DOMAIN выпущен"

  # --- добавляем SSL-блок (127.0.0.1:8080) к уже существующему блоку на порту 80 ---
  if [[ "$SITE_VERSION" == "1" ]]; then
    inf "Добавление обычного SSL-блока (127.0.0.1:8080) к конфигу, блок на порту 80 остаётся"
    cat >> "$SITE_CONF" <<EOF

server {
    listen 127.0.0.1:8080 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.3;
    ssl_conf_command Groups X25519MLKEM768:X25519;

    root ${WEBROOT};
    index index.html;

    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  else
    inf "Добавление SSL-блока под CDN (127.0.0.1:8080, proxy_protocol) к конфигу, блок на порту 80 остаётся"
    cat >> "$SITE_CONF" <<EOF

server {
    listen 127.0.0.1:8080 ssl proxy_protocol;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    root ${WEBROOT};
    index index.html;

    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;

    location /api/v4/lop {
        proxy_pass http://127.0.0.1:4443;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  fi

  nginx -t
  systemctl restart nginx
  ok "nginx настроен: порт 80 (acme-challenge/404) + 127.0.0.1:8080 (SSL-backend)"

  # --- проверка сертификата ---
  inf "Проверка сертификата через openssl s_client"
  openssl s_client -connect 127.0.0.1:8080 -servername "$DOMAIN" </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -dates

  ok "fallback-сайт для ${DOMAIN} настроен успешно."
}

########################################
# Главное меню
########################################
while true; do
  echo
  echo "Что выполнить?"
  echo "  1) rsyslog + traffic-guard"
  echo "  2) fallback-сайт (nginx + certbot)"
  echo "  3) всё подряд (1, 2)"
  echo "  0) выход"
  echo
  read -rp "Введите номера через запятую (например: 1,2), 3 для всего или 0 для выхода: " CHOICE
  CHOICE="$(echo -n "$CHOICE" | xargs)"

  if [[ -z "$CHOICE" ]]; then
    warn "Ничего не выбрано, попробуйте ещё раз."
    continue
  fi

  if [[ "$CHOICE" == "0" ]]; then
    inf "Выход."
    exit 0
  fi

  RUN_BASE=false; RUN_SITE=false
  BAD_CHOICE=false

  if [[ "$CHOICE" == "3" ]]; then
    RUN_BASE=true; RUN_SITE=true
  else
    IFS=',' read -ra PARTS <<< "$CHOICE"
    for p in "${PARTS[@]}"; do
      p="$(echo -n "$p" | xargs)"
      case "$p" in
        1) RUN_BASE=true ;;
        2) RUN_SITE=true ;;
        *) warn "Неизвестный пункт: '$p' (допустимо: 1, 2, 3, 0)"; BAD_CHOICE=true ;;
      esac
    done
  fi

  if $BAD_CHOICE; then
    continue
  fi

  SELECTED=""
  if $RUN_BASE; then SELECTED+="1 "; fi
  if $RUN_SITE; then SELECTED+="2 "; fi
  inf "Будут выполнены шаги: ${SELECTED}"
  echo

  if $RUN_BASE; then step_base_setup; fi
  if $RUN_SITE; then step_fallback_site; fi

  ok "Готово: выбранные шаги выполнены успешно."
  echo
  inf "Возврат в главное меню."
done
