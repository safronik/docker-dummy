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
# Репозиторий приложения (backend и frontend в одном). Обязателен для prod/test,
# по желанию для dev. Можно задать заранее через окружение.
CODE_REPO_URL="${CODE_REPO_URL:-}"
# Адрес для Let's Encrypt: ACME-аккаунт и письма об истечении сертификата.
# Обязателен для prod/test. Можно задать заранее через окружение.
SSL_EMAIL="${SSL_EMAIL:-}"
# UID/GID, под которые контейнеры подгоняют своих пользователей (www-data, node):
# файлы, создаваемые контейнером в code/, должны принадлежать хозяину каталога.
# Можно задать заранее через окружение, иначе берутся из среды ниже.
APP_UID="${APP_UID:-}"
APP_GID="${APP_GID:-}"
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

# valid_email VALUE — local@domain.tld из безопасного алфавита.
# Алфавит ограничен намеренно, как и у пароля БД: значение подставляется в файлы
# через sed, поэтому кавычки, '$' и '&' в нём недопустимы. Точную проверку адреса
# сделать нельзя — задача правила в том, чтобы поймать опечатку при вводе.
valid_email() {
    [[ "$1" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+$ ]]
}

# gen_password [LENGTH] — криптостойкий пароль из [A-Za-z0-9].
# Алфавит ограничен намеренно: значение попадает в URL (DATABASE_URL) и проходит
# через sed, поэтому символы '+', '/', '=', '$' и кавычки недопустимы.
gen_password() {
    local length="${1:-32}" raw="" chunk
    while (( ${#raw} < length )); do
        if command -v openssl >/dev/null 2>&1; then
            chunk="$(openssl rand -base64 48)"
        else
            # head первым в конвейере: после base64 закрытие трубы дало бы
            # SIGPIPE, а pipefail превратил бы это в падение скрипта
            chunk="$(head -c 48 /dev/urandom | base64)"
        fi
        raw+="${chunk//[^A-Za-z0-9]/}"
    done
    printf '%s' "${raw:0:length}"
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

# --- идентификаторы пользователя ----------------------------------------------
# Уезжают в .env и дальше в контейнеры: entrypoint'ы подгоняют под них www-data и
# node, иначе созданные контейнером файлы в code/ хосту не принадлежат.
# Запуск от root допустим (см. выше), тогда значения нулевые: файлы проекта
# принадлежат root, и контейнерные пользователи должны получить те же id.
# SUDO_UID не разбираем намеренно: скрипт целиком под sudo не запускают,
# sudo используется точечно для hosts.
[[ -n "$APP_UID" ]] || APP_UID="$(id -u)"
[[ -n "$APP_GID" ]] || APP_GID="$(id -g)"

# значение уходит в .env через sed и в usermod внутри контейнера — только цифры
[[ "$APP_UID" =~ ^[0-9]+$ ]] && (( APP_UID <= 2147483647 )) \
    || die "APP_UID must be a number in 0..2147483647, got: '$APP_UID'"
[[ "$APP_GID" =~ ^[0-9]+$ ]] && (( APP_GID <= 2147483647 )) \
    || die "APP_GID must be a number in 0..2147483647, got: '$APP_GID'"

if [[ "$APP_UID" == "0" || "$APP_GID" == "0" ]]; then
    echo "WARNING: APP_UID/APP_GID = 0, container users will get root's ids."
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

# --- APPLICATION CODE ---------------------------------------------------------
# prod/test: код обязан лежать в code/ до старта контейнеров — backend.entrypoint
# выполняет composer install, frontend.entrypoint падает без package.json.
# dev: по желанию. Отказ сохраняет прежнее поведение — контейнеры создают проект с нуля.
CODE_REPO_ENABLED=false
case "$ENV_STAGE" in
    prod|test)
        CODE_REPO_ENABLED=true
        if [[ -z "$CODE_REPO_URL" ]]; then
            ask CODE_REPO_URL "Application repository URL (must contain backend/ and frontend/)"
        fi
        [[ -n "$CODE_REPO_URL" ]] || die "Application repository URL is empty."
        ;;
    dev)
        # заранее переданный адрес — уже согласие, вопрос не задаём
        if [[ -n "$CODE_REPO_URL" ]]; then
            CODE_REPO_ENABLED=true
        elif ask_yn "Deploy existing application code from a repository?"; then
            CODE_REPO_ENABLED=true
            ask CODE_REPO_URL "Application repository URL (must contain backend/ and frontend/)"
            [[ -n "$CODE_REPO_URL" ]] || die "Application repository URL is empty."
        fi
        ;;
    blank)
        [[ -z "$CODE_REPO_URL" ]] \
            || die "CODE_REPO_URL is set, but stage 'blank' does not deploy application code."
        ;;
esac

# --- SSL ----------------------------------------------------------------------
# prod/test: сертификат выпускается автоматически, адрес обязателен — на него
# Let's Encrypt регистрирует аккаунт и шлёт письма об истечении.
# blank/dev: домены локальные, Let's Encrypt неприменим — значение остаётся пустым.
# Переданный заранее адрес не отбрасываем ни на одной стадии: он попадает в .env
# и доходит до роутера через LETSENCRYPT_EMAIL базового compose-файла.
case "$ENV_STAGE" in
    prod|test)
        if [[ -z "$SSL_EMAIL" ]]; then
            ask SSL_EMAIL "E-mail for Let's Encrypt (certificate expiry notices)"
        fi
        [[ -n "$SSL_EMAIL" ]] || die "SSL e-mail is empty, but stage '$ENV_STAGE' issues a certificate."
        ;;
esac

# проверяем на любой стадии: заранее переданный адрес тоже попадёт в .env
if [[ -n "$SSL_EMAIL" ]]; then
    valid_email "$SSL_EMAIL" || die "Invalid e-mail: '$SSL_EMAIL'. Expected form: name@example.com"
fi

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
DB_DATA_VOLUME="storage_data:/var/www"
DB_PORT_INTERNAL=5432
DB_COMMAND="postgres"
DB_PORT=5432
DB_SCHEME="postgresql"
DB_CHARSET="utf8"

if ask_yn "Do you need storage?"; then
    PROFILES+=(storage)

    echo "Choose database:"
    echo "  1 - PostgreSQL (default)"
    echo "  2 - MariaDB"
    ask DB_CHOICE "Your choice (1/2)" "1"

    case "$DB_CHOICE" in
        2)
            DB_DOCKERFILE="mariadb.dockerfile"
            DB_DATA_VOLUME="storage_data:/var/lib/mysql"
            DB_PORT_INTERNAL=3306
            # mariadbd, а не mysqld: mariadb.dockerfile собирается от mariadb:latest, где
            # совместимостного симлинка mysqld уже нет (проверено на MariaDB 12.3). С mysqld
            # сервер не стартует вовсе — command not found, контейнер уходит в рестарт-цикл.
            DB_COMMAND="mariadbd"
            DB_PORT=3306
            DB_SCHEME="mysql"
            DB_CHARSET="utf8mb4"
            ;;
        *)
            DB_DOCKERFILE="postgres.dockerfile"
            DB_DATA_VOLUME="storage_data:/var/lib/postgresql/data/pgdata"
            DB_PORT_INTERNAL=5432
            DB_COMMAND="postgres"
            DB_PORT=5432
            DB_SCHEME="postgresql"
            DB_CHARSET="utf8"
            ;;
    esac

    ask DB_PORT "Database outer port" "$DB_PORT"
fi

# --- сборка строки профилей ---------------------------------------------------
PROFILES_STR="$(IFS=','; printf '%s' "${PROFILES[*]:-}")"

echo "Profiles: ${PROFILES_STR:-<none>}"
echo "App UID/GID: $APP_UID/$APP_GID"
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

# --- код приложения -----------------------------------------------------------
# Клонируем до всех правок и до docker compose up: при неверном адресе на диске
# остаётся только каталог проекта, роутер и hosts ещё не тронуты.
# Клон полный (без --depth): code/ остаётся путём деплоя, обновления идут через git.
if [[ "$CODE_REPO_ENABLED" == true ]]; then
    git clone -- "$CODE_REPO_URL" code \
        || die "Cannot clone application repository. Check the URL and access rights. Remove '$PROJECT_DIR' before retrying."

    # проверяем ровно те файлы, без которых упадут entrypoint'ы контейнеров
    if [[ "$BACKEND" == true && ! -f code/backend/composer.json ]]; then
        die "Application repository has no 'backend/composer.json'. Remove '$PROJECT_DIR' before retrying."
    fi
    if [[ "$FRONTEND" == true && ! -f code/frontend/package.json ]]; then
        die "Application repository has no 'frontend/package.json'. Remove '$PROJECT_DIR' before retrying."
    fi

    # На prod/test docker-compose.prod.yml монтирует code/backend в контейнер
    # как read-only bind, а базовый docker-compose.yml монтирует поверх него
    # named volumes backend_var/backend_vendor/backend_uploads/backend_public_bundles.
    # Если этих подкаталогов нет физически на хосте (обычно в .gitignore
    # приложения), docker compose up падает: mkdir mountpoint внутри
    # read-only bind-mount невозможен.
    if [[ "$BACKEND" == true ]]; then
        mkdir -p code/backend/var code/backend/vendor code/backend/public/uploads code/backend/public/bundles
    fi

    echo "Application code deployed into code/"
fi

# --- .env ---------------------------------------------------------------------
subst .env COMPOSE_PROFILES   "$PROFILES_STR"
subst .env APP_UID            "$APP_UID"
subst .env APP_GID            "$APP_GID"
subst .env ENV_STAGE          "$ENV_STAGE"
subst .env PROJECT_NAME       "$PROJECT_NAME"
subst .env PROJECT_DOMAIN     "$PROJECT_DOMAIN"
subst .env SSL_EMAIL          "$SSL_EMAIL"
subst .env XDEBUG_REMOTE_PORT "$XDEBUG_REMOTE_PORT"
subst .env NODE_EXTERNAL_PORT "$NODE_EXTERNAL_PORT"
subst .env DB_PORT            "$DB_PORT"
# пароль не должен попасть в лог трассировки (DEBUG=1)
if [[ "${DEBUG:-0}" == "1" ]]; then set +x; fi
DB_PASSWORD="$(gen_password 32)"
subst .env DB_PASSWORD        "$DB_PASSWORD"
if [[ "${DEBUG:-0}" == "1" ]]; then set -x; fi
subst .env DB_DOCKERFILE      "$DB_DOCKERFILE"
subst .env DB_DATA_VOLUME     "$DB_DATA_VOLUME"
subst .env DB_PORT_INTERNAL   "$DB_PORT_INTERNAL"
subst .env DB_COMMAND         "$DB_COMMAND"
subst .env DB_SCHEME          "$DB_SCHEME"
subst .env DB_CHARSET         "$DB_CHARSET"

# страховка: если в шаблон добавили ключ, а сюда его вписать забыли — падаем сразу,
# а не через полчаса на непонятной ошибке контейнера
if grep -q '{[A-Z_][A-Z_]*}' .env; then
    die ".env contains unresolved placeholders: $(grep -o '{[A-Z_][A-Z_]*}' .env | tr '\n' ' ')"
fi

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
rm -f .gitattributes
rm -f .editorconfig
rm -rf .github
rm -rf .git
rm -f deploy.sh
rm -f deploy.ps1
rm -f "$LOCATION_FILE"
# и сам шаблон, из которого $LOCATION_FILE был скопирован, иначе он уезжает пользователю
rm -f dummy.domain_location

echo "Cleaned up"
pause
