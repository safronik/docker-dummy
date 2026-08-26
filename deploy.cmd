@echo off
setlocal enabledelayedexpansion
title Deploy new web project

::
:: Развёртывание нового web-проекта (Windows, порт с create_new_project.sh).
::
:: Требования: git, Docker Desktop (compose v2), PowerShell 5+, запуск от администратора.
:: Отладка:    set DEBUG=1 ^&^& create_new_project.cmd
::

:: --- настройки, которые раньше были зашиты в код ------------------------------
if not defined REPO_URL    set "REPO_URL=https://github.com/safronik/docker-dummy.git"
if not defined ROUTER_NAME set "ROUTER_NAME=router-nginx"
if not defined HOSTS_FILE  set "HOSTS_FILE=%SystemRoot%\System32\drivers\etc\hosts"

set "STEP=initialization"
set "ERRMSG="
set "SELF_DELETE="

if "%DEBUG%"=="1" echo on

:: --- проверка прав ------------------------------------------------------------
set "STEP=admin rights check"
net session >nul 2>&1
if errorlevel 1 goto :not_admin
echo OK! Running under admin.
goto :check_tools

:not_admin
echo ######## ########  ########   #######  ########
echo ##       ##     ## ##     ## ##     ## ##     ##
echo ##       ##     ## ##     ## ##     ## ##     ##
echo ######   ########  ########  ##     ## ########
echo ##       ##   ##   ##   ##   ##     ## ##   ##
echo ##       ##    ##  ##    ##  ##     ## ##    ##
echo ######## ##     ## ##     ##  #######  ##     ##
echo.
set "ERRMSG=Please run the script as administrator: it edits the hosts file."
goto :die

:: --- проверка окружения -------------------------------------------------------
:check_tools
set "STEP=environment check"
where git >nul 2>&1        || (set "ERRMSG=git not found in PATH." & goto :die)
where docker >nul 2>&1     || (set "ERRMSG=docker not found in PATH." & goto :die)
where powershell >nul 2>&1 || (set "ERRMSG=powershell not found in PATH." & goto :die)
docker info >nul 2>&1      || (set "ERRMSG=Docker daemon is not responding. Start Docker Desktop and retry." & goto :die)

set "PROFILES="

:: --- GENERAL SETTINGS ---------------------------------------------------------
set "STEP=user input"
call :ask DESTINATION    "Where to install? (absolute path, e.g. d:\docker)"
call :ask PROJECT_NAME   "Enter the project name"
call :ask PROJECT_DOMAIN "Enter the project first level domain"
call :ask ENV_STAGE      "Enter the environment stage (blank/dev/prod/test)" "dev"

if not defined DESTINATION    (set "ERRMSG=Destination is empty."    & goto :die)
if not defined PROJECT_NAME   (set "ERRMSG=Project name is empty."   & goto :die)
if not defined PROJECT_DOMAIN (set "ERRMSG=Project domain is empty." & goto :die)

:: имя и домен подставляются в файлы и в имя каталога — разрешаем только безопасные символы
call :validate_name "%PROJECT_NAME%"   "Project name"   || goto :die
call :validate_name "%PROJECT_DOMAIN%" "Project domain" || goto :die

:: убираем кавычки и хвостовой слэш из пути
set DESTINATION=%DESTINATION:"=%
if "%DESTINATION:~-1%"=="\" set "DESTINATION=%DESTINATION:~0,-1%"

if not exist "%DESTINATION%\" mkdir "%DESTINATION%" 2>nul
if not exist "%DESTINATION%\" (set "ERRMSG=Cannot create or access the destination folder. Check the path and permissions." & goto :die)

:: приводим к абсолютному пути
pushd "%DESTINATION%" || (set "ERRMSG=Cannot enter the destination folder." & goto :die)
set "DESTINATION=%CD%"
popd

set "ENV_STAGE_VALID="
if /i "%ENV_STAGE%"=="blank" set "ENV_STAGE_VALID=1"
if /i "%ENV_STAGE%"=="dev"   set "ENV_STAGE_VALID=1"
if /i "%ENV_STAGE%"=="prod"  set "ENV_STAGE_VALID=1"
if /i "%ENV_STAGE%"=="test"  set "ENV_STAGE_VALID=1"
if not defined ENV_STAGE_VALID (set "ERRMSG=Invalid environment stage: %ENV_STAGE%" & goto :die)

set "PROJECT_DIR=%DESTINATION%\%PROJECT_NAME%"
if exist "%PROJECT_DIR%" (set "ERRMSG=Directory already exists: %PROJECT_DIR%" & goto :die)

set "ROUTER_HOSTS_DIR=%DESTINATION%\router\config\nginx_hosts"
if not exist "%ROUTER_HOSTS_DIR%\" (set "ERRMSG=Router config dir not found: %ROUTER_HOSTS_DIR% - deploy the router first." & goto :die)

:: --- BACKEND ------------------------------------------------------------------
set "XDEBUG_REMOTE_PORT=9020"
call :ask_yn BACKEND "Do you need backend?"
if "%BACKEND%"=="true" call :ask XDEBUG_REMOTE_PORT "XDebug port (for IDE settings)" "%XDEBUG_REMOTE_PORT%"
if "%BACKEND%"=="true" set "PROFILES=%PROFILES%backend,"
call :validate_port "%XDEBUG_REMOTE_PORT%" "XDebug port" || goto :die

:: --- FRONTEND -----------------------------------------------------------------
set "NODE_EXTERNAL_PORT=5173"
call :ask_yn FRONTEND "Do you need frontend?"
if "%FRONTEND%"=="true" call :ask NODE_EXTERNAL_PORT "Node container external port" "%NODE_EXTERNAL_PORT%"
if "%FRONTEND%"=="true" set "PROFILES=%PROFILES%frontend,"
call :validate_port "%NODE_EXTERNAL_PORT%" "Node port" || goto :die

:: --- STORAGE ------------------------------------------------------------------
set "DB_DOCKERFILE=postgres.dockerfile"
set "DB_DATA_VOLUME=./data/postgres:/var/lib/postgresql/data/pgdata"
set "DB_PORT_INTERNAL=5432"
set "DB_COMMAND=postgres"
set "DB_PORT=5432"
set "DB_SCHEME=postgresql"
set "DB_CHARSET=utf8"

call :ask_yn STORAGE "Do you need storage?"
if not "%STORAGE%"=="true" goto :after_storage

set "PROFILES=%PROFILES%storage,"
echo Choose database:
echo   1 - PostgreSQL (default)
echo   2 - MariaDB
call :ask DB_CHOICE "Your choice (1/2)" "1"

if "%DB_CHOICE%"=="2" (
    set "DB_DOCKERFILE=mariadb.dockerfile"
    set "DB_DATA_VOLUME=./data/mysql:/var/lib/mysql"
    set "DB_PORT_INTERNAL=3306"
    set "DB_COMMAND=mysqld"
    set "DB_PORT=3306"
    set "DB_SCHEME=mysql"
    set "DB_CHARSET=utf8mb4"
)
if not "%DB_CHOICE%"=="1" if not "%DB_CHOICE%"=="2" (set "ERRMSG=Invalid database choice: %DB_CHOICE%" & goto :die)

call :ask DB_PORT "Database outer port" "!DB_PORT!"
call :validate_port "!DB_PORT!" "Database port" || goto :die

:after_storage
:: --- сборка строки профилей ---------------------------------------------------
if defined PROFILES set "PROFILES=%PROFILES:~0,-1%"

echo.
if defined PROFILES     echo Profiles: %PROFILES%
if not defined PROFILES echo Profiles: none
echo Your project is %PROJECT_NAME%.%PROJECT_DOMAIN%
echo Folder %PROJECT_DIR% will be created
pause

:: --- клонирование -------------------------------------------------------------
set "STEP=git clone %REPO_URL%"
cd /d "%DESTINATION%" || goto :fail
git clone "%REPO_URL%" ".\%PROJECT_NAME%" || goto :fail
cd /d "%PROJECT_DIR%" || goto :fail

:: --- .env ---------------------------------------------------------------------
set "STEP=patching .env"
call :subst ".env" "COMPOSE_PROFILES"   "%PROFILES%"          || goto :fail
call :subst ".env" "ENV_STAGE"          "%ENV_STAGE%"          || goto :fail
call :subst ".env" "PROJECT_NAME"       "%PROJECT_NAME%"       || goto :fail
call :subst ".env" "PROJECT_DOMAIN"     "%PROJECT_DOMAIN%"     || goto :fail
call :subst ".env" "XDEBUG_REMOTE_PORT" "%XDEBUG_REMOTE_PORT%" || goto :fail
call :subst ".env" "NODE_EXTERNAL_PORT" "%NODE_EXTERNAL_PORT%" || goto :fail
call :subst ".env" "DB_PORT"            "%DB_PORT%"            || goto :fail
call :gen_password DB_PASSWORD || goto :die
call :subst ".env" "DB_PASSWORD"        "!DB_PASSWORD!"        || goto :fail
call :subst ".env" "DB_DOCKERFILE"      "%DB_DOCKERFILE%"      || goto :fail
call :subst ".env" "DB_DATA_VOLUME"     "%DB_DATA_VOLUME%"     || goto :fail
call :subst ".env" "DB_PORT_INTERNAL"   "%DB_PORT_INTERNAL%"   || goto :fail
call :subst ".env" "DB_COMMAND"         "%DB_COMMAND%"         || goto :fail
call :subst ".env" "DB_SCHEME"          "%DB_SCHEME%"          || goto :fail
call :subst ".env" "DB_CHARSET"         "%DB_CHARSET%"         || goto :fail

:: страховка от забытых плейсхолдеров
findstr /r /c:"{[A-Z_][A-Z_]*}" ".env" >nul && (
    set "ERRMSG=.env contains unresolved placeholders."
    goto :die
)

:: --- php.ini ------------------------------------------------------------------
set "STEP=patching php.ini"
call :subst "config\php-ini\php.ini" "XDEBUG_REMOTE_PORT" "%XDEBUG_REMOTE_PORT%" || goto :fail

:: --- NGINX --------------------------------------------------------------------
set "STEP=patching nginx configs"
set "LOCATION_FILE=%PROJECT_NAME%.%PROJECT_DOMAIN%_location"
set "VHOST_DIR=config\nginx\vhost.d\%ENV_STAGE%"

if not exist "%VHOST_DIR%\" (set "ERRMSG=Vhost dir not found: %VHOST_DIR%" & goto :die)

copy /y "dummy.domain_location" "%LOCATION_FILE%" >nul || goto :fail
call :subst "%LOCATION_FILE%" "PROJECT_NAME" "%PROJECT_NAME%" || goto :fail

call :subst "%VHOST_DIR%\proxy.conf" "PROJECT_NAME"   "%PROJECT_NAME%"   || goto :fail
call :subst "%VHOST_DIR%\proxy.conf" "PROJECT_DOMAIN" "%PROJECT_DOMAIN%" || goto :fail

if "%BACKEND%"=="true" (
    call :subst "%VHOST_DIR%\modules\backend.conf" "PROJECT_NAME" "%PROJECT_NAME%" || goto :fail
) else (
    del /f /q "%VHOST_DIR%\modules\backend.conf" 2>nul
)
if not "%FRONTEND%"=="true" del /f /q "%VHOST_DIR%\modules\frontend.conf" 2>nul

echo Params copied to files

:: --- отдаём конфиг роутеру ----------------------------------------------------
set "STEP=copying config to router"
copy /y "%LOCATION_FILE%" "%ROUTER_HOSTS_DIR%\%LOCATION_FILE%" >nul || goto :fail
echo Nginx config created and copied to router
pause

del /f /q "data\mysql\.gitkeep"    2>nul
del /f /q "data\postgres\.gitkeep" 2>nul

:: --- compose override ---------------------------------------------------------
set "STEP=selecting compose override"
if exist "docker-compose.%ENV_STAGE%.yml" (
    copy /y "docker-compose.%ENV_STAGE%.yml" "docker-compose.override.yml" >nul || goto :fail
    echo Compose override for '%ENV_STAGE%' applied
)

:: --- docker -------------------------------------------------------------------
set "STEP=docker compose up"
set "COMPOSE_PROFILES=%PROFILES%"
docker compose up -d || goto :fail

set "STEP=restarting %ROUTER_NAME%"
docker restart "%ROUTER_NAME%" >nul || goto :fail
echo Main router restarted
pause

:: --- hosts --------------------------------------------------------------------
set "STEP=updating hosts file"
call :add_host "%PROJECT_NAME%.%PROJECT_DOMAIN%" || goto :fail
pause

:: --- уборка -------------------------------------------------------------------
set "STEP=cleanup"
cd /d "%PROJECT_DIR%" || goto :fail
del /f /q ".gitignore"             2>nul
del /f /q ".gitattributes"         2>nul
del /f /q ".editorconfig"          2>nul
if exist ".github\" rd /s /q ".github"
del /f /q "dummy.domain_location"  2>nul
del /f /q "%LOCATION_FILE%"        2>nul

:: конфиги nginx для неиспользуемых окружений
for /d %%D in ("config\nginx\vhost.d\*") do (
    if /i not "%%~nxD"=="%ENV_STAGE%" rd /s /q "%%~fD" 2>nul
)
:: стадийные заготовки compose, остаётся только применённый override
del /f /q "docker-compose.blank.yml" 2>nul
del /f /q "docker-compose.dev.yml"   2>nul
del /f /q "docker-compose.prod.yml"  2>nul
del /f /q "docker-compose.test.yml"  2>nul

if exist ".git\" attrib -r -h -s /s /d ".git\*" >nul 2>&1
if exist ".git\" rd /s /q ".git"

del /f /q "deploy.sh"  2>nul
del /f /q "deploy.ps1" 2>nul
:: сам себя батник удалить не может, пока выполняется — делаем это последней командой
if /i "%~f0"=="%PROJECT_DIR%\deploy.cmd" (set "SELF_DELETE=1") else (del /f /q "deploy.cmd" 2>nul)

echo Cleaned up
pause
if not defined SELF_DELETE goto :done
endlocal
(goto) 2>nul & del /f /q "%~f0"

:done
endlocal
exit /b 0

:: ============================ ПОДПРОГРАММЫ ====================================

:: ask VAR "prompt" ["default"] — set /p с поддержкой значения по умолчанию
:ask
set "__var=%~1"
set "__prompt=%~2"
set "__def=%~3"
set "__val="
if not defined __def goto :ask_nodef
set /p "__val=!__prompt! [!__def!]: "
goto :ask_done
:ask_nodef
set /p "__val=!__prompt!: "
:ask_done
if not defined __val set "__val=!__def!"
set "!__var!=!__val!"
exit /b 0

:: ask_yn VAR "prompt" — цикл до получения y/n, результат true/false
:ask_yn
set "__var=%~1"
set "__prompt=%~2"
:ask_yn_loop
set "__a="
set /p "__a=!__prompt! (y/n): "
if /i "!__a!"=="y"   goto :ask_yn_yes
if /i "!__a!"=="yes" goto :ask_yn_yes
if /i "!__a!"=="n"   goto :ask_yn_no
if /i "!__a!"=="no"  goto :ask_yn_no
echo Enter 'y' or 'n'.
goto :ask_yn_loop
:ask_yn_yes
set "!__var!=true"
exit /b 0
:ask_yn_no
set "!__var!=false"
exit /b 0

:: validate_name "value" "label" — только A-Z a-z 0-9 . _ -
:validate_name
echo(%~1| findstr /r /c:"^[A-Za-z0-9._-][A-Za-z0-9._-]*$" >nul
if errorlevel 1 (
    set "ERRMSG=%~2 contains invalid characters. Allowed: A-Z a-z 0-9 . _ -"
    exit /b 1
)
exit /b 0

:: validate_port "value" "label"
:validate_port
echo(%~1| findstr /r /c:"^[0-9][0-9]*$" >nul
if errorlevel 1 (
    set "ERRMSG=%~2 must be a number: %~1"
    exit /b 1
)
exit /b 0

:: subst FILE KEY VALUE — литеральная замена {KEY} на VALUE
:: без изменения кодировки и без превращения LF в CRLF
:subst
if not exist "%~1" (
    echo ERROR: file not found: %~1
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $f = (Resolve-Path -LiteralPath '%~1').Path; $t = [IO.File]::ReadAllText($f); $t = $t.Replace('{%~2}', '%~3'); [IO.File]::WriteAllText($f, $t, (New-Object System.Text.UTF8Encoding($false))); exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"
exit /b %ERRORLEVEL%

:: gen_password VAR — записывает в VAR случайный пароль из 32 символов [A-Za-z0-9]
::
:: В PowerShell-строке намеренно нет ни одного знака '%': она проходит две стадии
:: разбора cmd (сам батник и cmd /c, который порождает for /f), и правила схлопывания
:: %% на них разные. Поэтому вместо остатка от деления ($b[0] % 62) байты >= 62
:: отбрасываются — заодно уходит смещение распределения, которое давал бы остаток.
::
:: $ErrorActionPreference='Stop' + try/catch обязательны: без них отказ Create()
:: оставил бы $rng пустым, вызов метода у $null был бы нефатальной ошибкой,
:: а while($s.Length -lt 32) завис бы навсегда.
:gen_password
set "__pwd="
for /f "usebackq delims=" %%P in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { $a='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'; $rng=[System.Security.Cryptography.RandomNumberGenerator]::Create(); $b=New-Object byte[] 1; $s=''; while($s.Length -lt 32){ $rng.GetBytes($b); if($b[0] -lt $a.Length){ $s+=$a[$b[0]] } }; $rng.Dispose(); Write-Output $s; exit 0 } catch { exit 1 }"`) do set "__pwd=%%P"
if not defined __pwd (
    set "ERRMSG=Failed to generate DB password."
    exit /b 1
)
set "%~1=!__pwd!"
exit /b 0

:: add_host FQDN — добавляет запись, если её ещё нет; не ломает последнюю строку файла
:add_host
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $h = '%HOSTS_FILE%'; $n = '%~1'; $e = [Text.Encoding]::Default; $t = [IO.File]::ReadAllText($h, $e); $nl = [char]13 + [char]10; if ($t -match ('(?m)^\s*[\d\.]+[^\r\n]*\s' + [regex]::Escape($n) + '(\s|$)')) { Write-Host ('Hosts entry for ' + $n + ' already exists, skipped') } else { if ($t.Length -gt 0 -and $t[$t.Length-1] -ne [char]10) { $t += $nl }; $t += ('127.0.0.1 ' + $n + $nl); [IO.File]::WriteAllText($h, $t, $e); Write-Host 'Hosts updated' }; exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"
exit /b %ERRORLEVEL%

:: ============================ ВЫХОД С ОШИБКОЙ =================================

:: сбой внешней команды — аналог trap ERR
:fail
set "CODE=%ERRORLEVEL%"
if "%CODE%"=="0" set "CODE=1"
echo.
echo =============== ERROR ===============
echo  exit code : %CODE%
echo  step      : %STEP%
echo  directory : %CD%
echo =====================================
echo.
echo Script stopped. Read the message above.
pause
endlocal
exit /b %CODE%

:: ошибка валидации — аналог die()
:die
echo.
echo =============== ERROR ===============
echo  %ERRMSG%
echo  step      : %STEP%
echo  directory : %CD%
echo =====================================
echo.
pause
endlocal
exit /b 1
