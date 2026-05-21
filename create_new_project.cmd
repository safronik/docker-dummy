@echo off
setlocal enabledelayedexpansion

:: Check if is admin
NET SESSION >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo OK! Running under admin.
) else (
	echo ######## ########  ########   #######  ########
	echo ##       ##     ## ##     ## ##     ## ##     ##
	echo ##       ##     ## ##     ## ##     ## ##     ##
	echo ######   ########  ########  ##     ## ########
	echo ##       ##   ##   ##   ##   ##     ## ##   ##
	echo ##       ##    ##  ##    ##  ##     ## ##    ##
	echo ######## ##     ## ##     ##  #######  ##     ##
	echo .
	echo .
    echo Please run script under admin, beacuse it will edit the hosts file...
	pause
	exit
)

:: GATHER DATA
:: Install folder
set /p DESTINATION=Where to install? (Disk letter is required. for example 'd:\docker'):
:: get input
set /p PROJECT_NAME=Enter the project name:
set /p PROJECT_DOMAIN=Enter the project first level domain:
set /p XDEBUG_REMOTE_PORT=XDebug port(for IDE settings):
:: DB choice
echo.
echo Choose database:
echo   1 - PostgreSQL (default)
echo   2 - MariaDB
set /p DB_CHOICE=Your choice (1/2):

if "%DB_CHOICE%"=="1" (
    set DB_DOCKERFILE=postgres.dockerfile
    set DB_DATA_VOLUME=./data/postgres:/var/lib/postgresql/data/pgdata
    set DB_PORT_INTERNAL=5432
    set DB_COMMAND=postgres
    set DB_PORT=5432
)
if "%DB_CHOICE%"=="2" (
    set DB_DOCKERFILE=mariadb.dockerfile
    set DB_DATA_VOLUME=./data/mysql:/var/lib/mysql
    set DB_PORT_INTERNAL=3306
    set DB_COMMAND=mysqld
    set DB_PORT=3306
)
set /p DB_PORT=Database outer port [!DB_PORT!]:
if "!DB_PORT!"=="" (
    if "%DB_CHOICE%"=="1" (set DB_PORT=5432)
    if "%DB_CHOICE%"=="2" (set DB_PORT=3306)
)

echo "Your project is %PROJECT_NAME%.%PROJECT_DOMAIN%"
echo "Folder %DESTINATION%\%PROJECT_NAME% will be created"
pause

:: Install and run main router
REM docker ps -a -q -f name="router"
REM {
	:: cloning repo
	REM git clone https://github.com/safronik/docker-router.git ./router
	REM cd ./router
	REM docker compose up -d
	REM cd ..
REM }
:: Start container
REM docker container start router-nginx

:: get into destination directory
cd /d %DESTINATION%
:: cloning repo
git clone https://github.com/safronik/docker-dummy.git ./%PROJECT_NAME%
:: get into project directory
cd .\%PROJECT_NAME%

:: change placeholders in .env file
powershell -Command "(gc .env) -replace '{PROJECT_NAME}', '%PROJECT_NAME%' | Out-File -encoding ASCII .env"
powershell -Command "(gc .env) -replace '{PROJECT_DOMAIN}', '%PROJECT_DOMAIN%' | Out-File -encoding ASCII .env"
powershell -Command "(gc .env) -replace '{XDEBUG_REMOTE_PORT}', '%XDEBUG_REMOTE_PORT%' | Out-File -encoding ASCII .env"
:: change placeholders for database
powershell -Command "(gc .env) -replace '{DB_PORT}', '%DB_PORT%' | Out-File -encoding ASCII .env"
powershell -Command "(gc .env) -replace '{DB_PASSWORD}', '%PROJECT_NAME%' | Out-File -encoding ASCII .env"
powershell -Command "(gc .env) -replace '{DB_DOCKERFILE}',    '%DB_DOCKERFILE%'    | Out-File -encoding ASCII .env"
powershell -Command "(gc .env) -replace '{DB_DATA_VOLUME}',   '%DB_DATA_VOLUME%'   | Out-File -encoding ASCII .env"
powershell -Command "(gc .env) -replace '{DB_PORT_INTERNAL}', '%DB_PORT_INTERNAL%' | Out-File -encoding ASCII .env"
powershell -Command "(gc .env) -replace '{DB_COMMAND}',       '%DB_COMMAND%'       | Out-File -encoding ASCII .env"
:: change placeholders in php.ini
powershell -Command "(gc .\config\php-ini\php.ini) -replace '{XDEBUG_REMOTE_PORT}', '%XDEBUG_REMOTE_PORT%' | Out-File -encoding ASCII .\config\php-ini\php.ini"
:: change placeholders in NGINX configuration
powershell -Command "(gc dummy.domain_location) -replace '{PROJECT_NAME}', '%PROJECT_NAME%'                | Out-File -encoding ASCII %PROJECT_NAME%.%PROJECT_DOMAIN%_location"
powershell -Command "(gc .\config\nginx\vhost.d\site.conf) -replace '{PROJECT_NAME}', '%PROJECT_NAME%'     | Out-File -encoding ASCII .\config\nginx\vhost.d\site.conf"
powershell -Command "(gc .\config\nginx\vhost.d\site.conf) -replace '{PROJECT_DOMAIN}', '%PROJECT_DOMAIN%' | Out-File -encoding ASCII .\config\nginx\vhost.d\site.conf"
echo "Params copied to files"

:: send file to router vhost dir and clean up
copy .\%PROJECT_NAME%.%PROJECT_DOMAIN%_location ..\router\config\nginx_hosts\%PROJECT_NAME%.%PROJECT_DOMAIN%_location
echo "Nginx config created and copied to router"
pause

erase data\mysql\.gitkeep
erase data\postgres\.gitkeep

:: init docker
@REM docker login
@REM docker compose up -d

:: restart main router
@REM docker restart router-nginx
echo "Main router restarted"
pause

:: append hosts file
C:
cd \Windows\System32\drivers\etc\
powershell -Command "Add-Content -Path .\hosts '127.0.0.1 %PROJECT_NAME%.%PROJECT_DOMAIN%'"
echo "Hosts updated"
pause

:: Cleaning up
:: Return to docker folder
cd /d %DESTINATION%\%PROJECT_NAME%
:: Clean up
erase .gitignore
rd /s/q .git
:: erase .env
:: erase docker-compose.yml
erase dummy.domain_location
erase %PROJECT_NAME%.%PROJECT_DOMAIN%_location
:: rd /s/q dockerfiles

echo "Cleaned up"
pause