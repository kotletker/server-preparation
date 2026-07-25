#!/usr/bin/env bash
#
# setup-server.sh
#
# 1) rsyslog
# 2) traffic-guard (dotX12/traffic-guard) с antiscanner + government_networks листами
# 3) fallback-сайт (nginx + certbot) на основе шаблона из eGamesAPI/simple-web-templates,
#    домен запрашивается интерактивно и сверяется с внешним IP сервера
#
# Перед запуском спрашивает, какие шаги выполнять (по отдельности или всё подряд).
# Останавливается на первой же ошибке любого шага.

set -euo pipefail

# ---------- оформление ----------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[36m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
inf()  { echo -e "${BLUE}[*]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[ОШИБКА]${RESET} $*" >&2; }

trap 'err "Скрипт остановлен из-за ошибки на строке $LINENO. Выполнение прервано."; exit 1' ERR

if [[ $EUID -ne 0 ]]; then
  err "Запускайте скрипт от root (sudo bash $0)."
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  inf "Установка curl (требуется для дальнейших шагов)"
  apt update
  apt install -y curl
fi

########################################
# Меню выбора шагов
########################################
echo "Что выполнить?"
echo "  1) rsyslog"
echo "  2) traffic-guard"
echo "  3) fallback-сайт (nginx + certbot)"
echo "  0) всё подряд (1, 2, 3)"
echo
read -rp "Введите номера через запятую (например: 1,3) или 0 для всего: " CHOICE
CHOICE="$(echo -n "$CHOICE" | xargs)"

RUN_1=false; RUN_2=false; RUN_3=false
if [[ -z "$CHOICE" ]]; then
  err "Ничего не выбрано."
  exit 1
fi

if [[ "$CHOICE" == "0" ]]; then
  RUN_1=true; RUN_2=true; RUN_3=true
else
  IFS=',' read -ra PARTS <<< "$CHOICE"
  for p in "${PARTS[@]}"; do
    p="$(echo -n "$p" | xargs)"
    case "$p" in
      1) RUN_1=true ;;
      2) RUN_2=true ;;
      3) RUN_3=true ;;
      *) err "Неизвестный пункт: '$p' (допустимо: 1, 2, 3, 0)"; exit 1 ;;
    esac
  done
fi

SELECTED=""
if $RUN_1; then SELECTED+="1 "; fi
if $RUN_2; then SELECTED+="2 "; fi
if $RUN_3; then SELECTED+="3 "; fi
inf "Будут выполнены шаги: ${SELECTED}"
echo

########################################
# 1) rsyslog
########################################
step_rsyslog() {
  inf "Шаг 1: установка rsyslog"
  apt update
  apt install rsyslog -y
  systemctl enable --now rsyslog
  systemctl restart rsyslog
  ok "rsyslog установлен и запущен"
}

########################################
# 2) traffic-guard
########################################
step_traffic_guard() {
  inf "Шаг 2: установка traffic-guard"
  curl -fsSL https://raw.githubusercontent.com/dotX12/traffic-guard/master/install.sh | bash

  traffic-guard full \
    -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list \
    -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list \
    --enable-logging
  ok "traffic-guard установлен и настроен"
}

########################################
# 3) fallback-сайт: домен, nginx, certbot
########################################
step_fallback_site() {
  inf "Шаг 3: настройка fallback-сайта"

  if ! command -v dig >/dev/null 2>&1; then
    apt install -y dnsutils
  fi

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

  DOMAIN_IP="$(dig +short A "$DOMAIN" | tail -n1)"
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

  # --- каталог сайта + случайный шаблон ---
  inf "Создание $WEBROOT и загрузка случайного шаблона"
  mkdir -p "$WEBROOT"

  if ! command -v unzip >/dev/null 2>&1; then
    inf "Установка unzip"
    apt install -y unzip
  fi

  TMP_DIR="$(mktemp -d)"
  curl -fsSL -o "$TMP_DIR/templates.zip" \
    https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/master.zip
  unzip -q "$TMP_DIR/templates.zip" -d "$TMP_DIR"
  TEMPLATES_DIR="$TMP_DIR/simple-web-templates-master"
  rm -rf "$TEMPLATES_DIR/assets" "$TEMPLATES_DIR/.gitattributes" \
         "$TEMPLATES_DIR/README.md" "$TEMPLATES_DIR/_config.yml" \
         "$TEMPLATES_DIR/random_site.sh"

  RANDOM_TEMPLATE="$(find "$TEMPLATES_DIR" -mindepth 1 -maxdepth 1 -type d | shuf -n1)"
  if [[ -z "$RANDOM_TEMPLATE" ]]; then
    err "Не удалось выбрать шаблон сайта."
    exit 1
  fi
  inf "Выбран шаблон: $(basename "$RANDOM_TEMPLATE")"

  rm -rf "${WEBROOT:?}"/*
  cp -a "$RANDOM_TEMPLATE"/. "$WEBROOT"/
  rm -rf "$TMP_DIR"
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
  inf "Добавление SSL-блока (127.0.0.1:8080) к конфигу, блок на порту 80 остаётся"
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
# Запуск выбранных шагов
########################################
if $RUN_1; then step_rsyslog; fi
if $RUN_2; then step_traffic_guard; fi
if $RUN_3; then step_fallback_site; fi

ok "Готово: выбранные шаги выполнены успешно."
