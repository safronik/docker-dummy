#!/usr/bin/env bash
#
# Развёртывание нового web-проекта (порт create_new_project.cmd).
#
# Требования: bash 4+, git, docker c compose v2, GNU sed, sudo (только для hosts).
# Запуск:     ./create_new_project.sh   (НЕ от root — см. блок проверки прав)
#
set -Eeuo pipefail

# --- настройки, которые раньше были зашиты в код ------------------------------
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"   # WSL: /mnt/c/Windows/System32/drivers/etc/hosts
REPO_URL="${REPO_URL:-https://github.com/safronik/docker-dummy.git}"
ROUTER_NAME="${ROUTER_NAME:-router-nginx}"
LOG_FILE="${LOG_FILE:-./create_new_project.trace.log}"

# --- обработка ошибок ---------------------------------------------------------
# Ловим упавшую команду, печатаем строку/команду/каталог и ЖДЁМ нажатия клавиши,
# чтобы окно терминала не закрылось раньше, чем сообщение будет прочитано.
on_err() {
    local code=$? line=$1 cmd=$2
    {
        echo
        echo "=============== ОШИБКА ==============="
        echo " код возврата : $code"
        echo " строка       : $line"
        echo " команда      : $cmd"
        echo " каталог      : $PWD"
        echo "======================================"
    } >&2
}

on_exit() {
    local code=$?
    if (( code != 0 )); then
        echo >&2
        echo "Скрипт остановлен с кодом $code. Прочитайте сообщение выше." >&2
        if [[ -t 0 ]]; then
            read -r -n 1 -s -p "Нажмите любую клавишу для выхода..." || true
            echo >&2
        fi
    fi
    return 0
}

trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
trap on_exit EXIT

# DEBUG=1 ./create_new_project.sh — построчная трассировка в отдельный файл,
# чтобы не мешать интерактивным вопросам в терминале.
if [[ "${DEBUG:-0}" == "1" ]]; then
    exec 9>"$LOG_FILE"
    export BASH_XTRACEFD=9
    set -x
    echo "Трассировка пишется в $LOG_FILE"
fi

# --- вспомогательные функции --------------------------------------------------
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

pause() { read -r -n 1 -s -p "Press any key to continue..." || true; echo; }

# ask VAR "prompt" ["default"]  — замена `set /p`
ask() {
    local __var="$1" __prompt="$2" __default="${3-}" __input
    if [[ -n "$__default" ]]; then
        read -r -p "$__prompt [$__default]: " __input
        __input="${__input:-$__default}"
    else
        read -r -p "$__prompt: " __input
    fi
    printf -v "$__var" '%s' "$__input"
}

# ask_yn "prompt" -> код возврата 0 (да) / 1 (нет)
ask_yn() {
    local __answer
    while true; do
        read -r -p "$1 (y/n): " __answer
        case "${__answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     echo "Enter 'y' or 'n'." ;;
        esac
    done
}

# subst FILE KEY VALUE — замена {KEY} на VALUE, замена powershell -replace
subst() {
    local file="$1" key="$2" val="$3" esc
    [[ -f "$file" ]] || die "File not found: $file"
    # экранируем символы, значимые для правой части sed s|||
    esc=$(printf '%s' "$val" | sed -e 's/[&|\\]/\\&/g')
    sed -i "s|{$key}|$esc|g" "$file"
}

# --- проверка окружения -------------------------------------------------------
for bin in git docker sed; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found in PATH."
done

if [[ $EUID -eq 0 ]]; then
    # запуск от root допустим, но склонированные файлы будут принадлежать root
    SUDO=""
    echo "WARNING: running as root, project files will be owned by root."
else
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        cat <<'EOF'
######## ########  ########   #######  ########
##       ##     ## ##     ## ##     ## ##     ##
##       ##     ## ##     ## ##     ## ##     ##
######   ########  ########  ##     ## ########
##       ##   ##   ##   ##   ##     ## ##   ##
##       ##    ##  ##    ##  ##     ## ##    ##
######## ##     ## ##     ##  #######  ##     ##

'sudo' not found and you are not root: cannot edit the hosts file.
EOF
        exit 1
    fi
fi

PROFILES=()

# --- GENERAL SETTINGS ---------------------------------------------------------
ask DESTINATION  "Where to install? (absolute path, e.g. '/home/user/docker')"
ask PROJECT_NAME "Enter the project name"
ask PROJECT_DOMAIN "Enter the project first level domain"
ask ENV_STAGE    "Enter the environment stage (blank/dev/prod/test)"

[[ -n "$DESTINATION"    ]] || die "Destination is empty."
[[ -n "$PROJECT_NAME"   ]] || die "Project name is empty."
[[ -n "$PROJECT_DOMAIN" ]] || die "Project domain is empty."

# Проверяем каталог установки СРАЗУ, а не после всех вопросов.
DESTINATION="${DESTINATION/#\~/$HOME}"                  # раскрываем ~
DESTINATION="${DESTINATION%/}"                          # убираем хвостовой /
if [[ "$DESTINATION" == *'\'* ]]; then
    die "Path contains backslashes: '$DESTINATION'. Use '/home/user/docker', not 'd:\\docker'."
fi
if [[ ! -d "$DESTINATION" ]]; then
    mkdir -p "$DESTINATION" 2>/dev/null \
        || die "Cannot create '$DESTINATION'. Check the path and permissions (try a path inside \$HOME)."
fi
[[ -w "$DESTINATION" ]] || die "No write permission for '$DESTINATION' (user: $(id -un))."
DESTINATION="$(cd "$DESTINATION" && pwd)"               # приводим к абсолютному пути

case "$ENV_STAGE" in
    blank|dev|prod|test) ;;
    *) die "Invalid environment stage: '$ENV_STAGE'" ;;
esac

# --- BACKEND ------------------------------------------------------------------
XDEBUG_REMOTE_PORT=9020
BACKEND=false
if ask_yn "Do you need backend?"; then
    BACKEND=true
    PROFILES+=(backend)
    ask XDEBUG_REMOTE_PORT "XDebug port (for IDE settings)" "$XDEBUG_REMOTE_PORT"
fi

# --- FRONTEND -----------------------------------------------------------------
NODE_EXTERNAL_PORT=5173
FRONTEND=false
if ask_yn "Do you need frontend?"; then
    FRONTEND=true
    PROFILES+=(frontend)
    ask NODE_EXTERNAL_PORT "Node container external port" "$NODE_EXTERNAL_PORT"
fi

# --- STORAGE ------------------------------------------------------------------
DB_DOCKERFILE="postgres.dockerfile"
DB_DATA_VOLUME="./data/dummy:/var/www"
DB_PORT_INTERNAL=5432
DB_COMMAND="postgres"
DB_PORT=5432

if ask_yn "Do you need storage?"; then
    PROFILES+=(storage)

    echo "Choose database:"
    echo "  1 - PostgreSQL (default)"
    echo "  2 - MariaDB"
    ask DB_CHOICE "Your choice (1/2)" "1"

    case "$DB_CHOICE" in
        2)
            DB_DOCKERFILE="mariadb.dockerfile"
            DB_DATA_VOLUME="./data/mysql:/var/lib/mysql"
            DB_PORT_INTERNAL=3306
            DB_COMMAND="mysqld"
            DB_PORT=3306
            ;;
        *)
            DB_DOCKERFILE="postgres.dockerfile"
            DB_DATA_VOLUME="./data/postgres:/var/lib/postgresql/data/pgdata"
            DB_PORT_INTERNAL=5432
            DB_COMMAND="postgres"
            DB_PORT=5432
            ;;
    esac

    ask DB_PORT "Database outer port" "$DB_PORT"
fi

# --- сборка строки профилей ---------------------------------------------------
PROFILES_STR="$(IFS=','; printf '%s' "${PROFILES[*]:-}")"

echo "Profiles: ${PROFILES_STR:-<none>}"
echo "Your project is $PROJECT_NAME.$PROJECT_DOMAIN"
echo "Folder $DESTINATION/$PROJECT_NAME will be created"
pause

# --- клонирование -------------------------------------------------------------
PROJECT_DIR="$DESTINATION/$PROJECT_NAME"
if [[ -e "$PROJECT_DIR" ]]; then
    die "Directory already exists: $PROJECT_DIR"
fi

cd "$DESTINATION"
git clone "$REPO_URL" "./$PROJECT_NAME"
cd "./$PROJECT_NAME"

# --- .env ---------------------------------------------------------------------
subst .env COMPOSE_PROFILES   "$PROFILES_STR"
subst .env ENV_STAGE          "$ENV_STAGE"
subst .env PROJECT_NAME       "$PROJECT_NAME"
subst .env PROJECT_DOMAIN     "$PROJECT_DOMAIN"
subst .env XDEBUG_REMOTE_PORT "$XDEBUG_REMOTE_PORT"
subst .env NODE_EXTERNAL_PORT "$NODE_EXTERNAL_PORT"
subst .env DB_PORT            "$DB_PORT"
subst .env DB_PASSWORD        "$PROJECT_NAME"
subst .env DB_DOCKERFILE      "$DB_DOCKERFILE"
subst .env DB_DATA_VOLUME     "$DB_DATA_VOLUME"
subst .env DB_PORT_INTERNAL   "$DB_PORT_INTERNAL"
subst .env DB_COMMAND         "$DB_COMMAND"

# --- php.ini ------------------------------------------------------------------
subst "config/php-ini/php.ini" XDEBUG_REMOTE_PORT "$XDEBUG_REMOTE_PORT"

# --- NGINX --------------------------------------------------------------------
LOCATION_FILE="${PROJECT_NAME}.${PROJECT_DOMAIN}_location"
cp "dummy.domain_location" "$LOCATION_FILE"
subst "$LOCATION_FILE" PROJECT_NAME "$PROJECT_NAME"

VHOST_DIR="config/nginx/vhost.d/$ENV_STAGE"
subst "$VHOST_DIR/proxy.conf" PROJECT_NAME   "$PROJECT_NAME"
subst "$VHOST_DIR/proxy.conf" PROJECT_DOMAIN "$PROJECT_DOMAIN"

if [[ "$BACKEND" == true ]]; then
    subst "$VHOST_DIR/modules/backend.conf" PROJECT_NAME "$PROJECT_NAME"
else
    rm -f "$VHOST_DIR/modules/backend.conf"
fi

if [[ "$FRONTEND" != true ]]; then
    rm -f "$VHOST_DIR/modules/frontend.conf"
fi

echo "Params copied to files"

# --- отдаём конфиг роутеру ----------------------------------------------------
ROUTER_HOSTS_DIR="$DESTINATION/router/config/nginx_hosts"
[[ -d "$ROUTER_HOSTS_DIR" ]] || die "Router config dir not found: $ROUTER_HOSTS_DIR"
cp "$LOCATION_FILE" "$ROUTER_HOSTS_DIR/$LOCATION_FILE"
echo "Nginx config created and copied to router"
pause

rm -f data/mysql/.gitkeep data/postgres/.gitkeep

# --- compose override ---------------------------------------------------------
if [[ -f "docker-compose.$ENV_STAGE.yml" ]]; then
    cp "docker-compose.$ENV_STAGE.yml" docker-compose.override.yml
    echo "Compose override for '$ENV_STAGE' applied"
fi

# --- docker -------------------------------------------------------------------
export COMPOSE_PROFILES="$PROFILES_STR"
docker compose up -d

docker restart "$ROUTER_NAME"
echo "Main router restarted"
pause

# --- hosts --------------------------------------------------------------------
FQDN="${PROJECT_NAME}.${PROJECT_DOMAIN}"
if grep -qwF "$FQDN" "$HOSTS_FILE"; then
    echo "Hosts entry for $FQDN already exists, skipped"
else
    printf '127.0.0.1 %s\n' "$FQDN" | $SUDO tee -a "$HOSTS_FILE" >/dev/null
    echo "Hosts updated"
fi
pause

# --- уборка -------------------------------------------------------------------
cd "$PROJECT_DIR"

# удаляем конфиги nginx для неиспользуемых окружений
for vhost in config/nginx/vhost.d/*/; do
    [[ -d "$vhost" ]] || continue
    [[ "$(basename "$vhost")" == "$ENV_STAGE" ]] && continue
    rm -rf "$vhost"
done

# удаляем стадийные заготовки compose, остаётся только применённый override
rm -f docker-compose.{blank,dev,prod,test}.yml

rm -f .gitignore
rm -rf .git
rm -f create_new_project.cmd
rm -f create_new_project.sh
rm -f create_new_project.ps1
rm -f "$LOCATION_FILE"

echo "Cleaned up"
pause
