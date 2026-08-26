#Requires -Version 5.1
<#
.SYNOPSIS
    Развёртывание нового web-проекта (порт create_new_project.sh / .cmd).

.DESCRIPTION
    Клонирует шаблон docker-dummy, подставляет параметры в .env, php.ini и конфиги nginx,
    отдаёт location-файл роутеру, поднимает контейнеры и правит hosts.

    Любой параметр, не переданный в командной строке, будет запрошен интерактивно.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\create_new_project.ps1

.EXAMPLE
    .\create_new_project.ps1 -Destination D:\docker -ProjectName shop -ProjectDomain local `
                             -EnvStage dev -Backend -Frontend -Database postgres

.NOTES
    Требуется запуск от администратора (правка hosts), git и запущенный Docker Desktop.
#>
[CmdletBinding()]
param(
    [string] $Destination,
    [string] $ProjectName,
    [string] $ProjectDomain,

    [ValidateSet('blank', 'dev', 'prod', 'test')]
    [string] $EnvStage,

    [switch] $Backend,
    [switch] $Frontend,

    [ValidateSet('none', 'postgres', 'mariadb')]
    [string] $Database,

    [ValidateRange(1, 65535)] [int] $XdebugPort = 9020,
    [ValidateRange(1, 65535)] [int] $NodePort   = 5173,
    [ValidateRange(1, 65535)] [int] $DbPort,

    [string] $RepoUrl    = 'https://github.com/safronik/docker-dummy.git',
    [string] $RouterName = 'router-nginx',
    [string] $HostsFile  = "$env:SystemRoot\System32\drivers\etc\hosts",

    # Не удалять .git и скрипты установки после развёртывания
    [switch] $KeepSources,

    # Аналог DEBUG=1 в bash-версии: построчная трассировка в файл
    [switch] $Trace
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$script:Step = 'initialization'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ------------------------------------------------------------------ функции --

function Set-Step {
    param([Parameter(Mandatory)][string] $Name)
    $script:Step = $Name
    Write-Verbose "== $Name"
}

function Wait-Key {
    param([string] $Message = 'Press any key to continue...')
    if ([Console]::IsInputRedirected) { return }
    Write-Host $Message -NoNewline
    [void][Console]::ReadKey($true)
    Write-Host
}

# Запуск внешней программы с проверкой кода возврата.
# git и docker пишут прогресс в stderr, поэтому внутри временно снимаем
# ErrorActionPreference = Stop, иначе PowerShell 5.1 бросит NativeCommandError
# на совершенно штатном выводе.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]   $FilePath,
        [Parameter(Mandatory)][string[]] $Arguments
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0) {
        throw "Команда завершилась с кодом $code : $FilePath $($Arguments -join ' ')"
    }
}

function Read-Value {
    param(
        [Parameter(Mandatory)][string] $Prompt,
        [string] $Default,
        [string] $Pattern,
        [string] $PatternMessage = 'Недопустимое значение, попробуйте ещё раз.'
    )
    while ($true) {
        $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $value = (Read-Host $label).Trim().Trim('"')
        if (-not $value -and $Default) { $value = $Default }
        if (-not $value) { Write-Host 'Значение не может быть пустым.' -ForegroundColor Yellow; continue }
        if ($Pattern -and $value -notmatch $Pattern) { Write-Host $PatternMessage -ForegroundColor Yellow; continue }
        return $value
    }
}

function Read-YesNo {
    param([Parameter(Mandatory)][string] $Prompt)
    while ($true) {
        $answer = (Read-Host "$Prompt (y/n)").Trim().ToLowerInvariant()
        if ($answer -in @('y', 'yes')) { return $true }
        if ($answer -in @('n', 'no'))  { return $false }
        Write-Host "Введите 'y' или 'n'." -ForegroundColor Yellow
    }
}

function Read-Port {
    param([Parameter(Mandatory)][string] $Prompt, [Parameter(Mandatory)][int] $Default)
    while ($true) {
        $value = Read-Value -Prompt $Prompt -Default "$Default" -Pattern '^\d+$' -PatternMessage 'Порт — это число.'
        $port = [int]$value
        if ($port -ge 1 -and $port -le 65535) { return $port }
        Write-Host 'Порт должен быть в диапазоне 1-65535.' -ForegroundColor Yellow
    }
}

# Литеральная (не regex) замена {KEY} на значение.
# Кодировка — UTF-8 без BOM, переводы строк исходного файла не меняются:
# CRLF в .env оставляет \r в значениях переменных docker compose.
function Set-Placeholders {
    param(
        [Parameter(Mandatory)][string]    $Path,
        [Parameter(Mandatory)][hashtable] $Map
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Файл не найден: $Path" }
    $full = (Resolve-Path -LiteralPath $Path).Path
    $text = [IO.File]::ReadAllText($full)
    foreach ($key in $Map.Keys) {
        $text = $text.Replace('{' + $key + '}', [string]$Map[$key])
    }
    [IO.File]::WriteAllText($full, $text, $script:Utf8NoBom)
}

function Add-HostsEntry {
    param([Parameter(Mandatory)][string] $Fqdn, [Parameter(Mandatory)][string] $Path)

    $raw = ''
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
        if ($null -eq $raw) { $raw = '' }
    }

    $pattern = '(?m)^\s*[\d\.]+[^\r\n]*\s' + [regex]::Escape($Fqdn) + '(\s|$)'
    if ($raw -match $pattern) {
        Write-Host "Hosts entry for $Fqdn already exists, skipped"
        return
    }

    # если файл не заканчивается переводом строки — сначала дописываем его,
    # иначе новая запись приклеится к последней строке
    if ($raw.Length -gt 0 -and $raw[-1] -ne "`n") {
        Add-Content -LiteralPath $Path -Value ''
    }
    Add-Content -LiteralPath $Path -Value "127.0.0.1 $Fqdn"
    Write-Host 'Hosts updated'
}

function Remove-ItemSafe {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    # снимаем read-only с объектов .git, иначе Remove-Item может упасть
    Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReadOnly } |
        ForEach-Object { $_.Attributes = 'Normal' }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- основной ---

$transcriptStarted = $false
try {
    if ($Trace) {
        $log = Join-Path (Get-Location) 'create_new_project.trace.log'
        Start-Transcript -Path $log -Force | Out-Null
        $transcriptStarted = $true
        Set-PSDebug -Trace 1
        Write-Host "Трассировка пишется в $log"
    }

    # --- проверка прав --------------------------------------------------------
    Set-Step 'проверка прав администратора'
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Запустите скрипт от администратора: он правит файл hosts.'
    }
    Write-Host 'OK! Running under admin.' -ForegroundColor Green

    # --- проверка окружения ---------------------------------------------------
    Set-Step 'проверка окружения'
    foreach ($tool in 'git', 'docker') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "'$tool' не найден в PATH."
        }
    }
    Invoke-Native docker @('info', '--format', '{{.ServerVersion}}') | Out-Null

    # --- общие настройки ------------------------------------------------------
    Set-Step 'ввод параметров'

    if (-not $Destination) {
        $Destination = Read-Value -Prompt "Куда установить? (абсолютный путь, например 'D:\docker')"
    }
    $Destination = $Destination.Trim().Trim('"').TrimEnd('\')

    if (-not $ProjectName) {
        $ProjectName = Read-Value -Prompt 'Имя проекта' -Pattern '^[A-Za-z0-9._-]+$' `
            -PatternMessage 'Допустимы только A-Z a-z 0-9 . _ -'
    }
    if (-not $ProjectDomain) {
        $ProjectDomain = Read-Value -Prompt 'Домен первого уровня' -Pattern '^[A-Za-z0-9._-]+$' `
            -PatternMessage 'Допустимы только A-Z a-z 0-9 . _ -'
    }
    if (-not $EnvStage) {
        $EnvStage = Read-Value -Prompt 'Окружение (blank/dev/prod/test)' -Default 'dev' `
            -Pattern '^(blank|dev|prod|test)$' -PatternMessage 'Недопустимое окружение.'
    }

    # имя и домен попадают в имя каталога и в конфиги — проверяем даже то, что пришло параметром
    foreach ($pair in @(@{ n = 'ProjectName'; v = $ProjectName }, @{ n = 'ProjectDomain'; v = $ProjectDomain })) {
        if ($pair.v -notmatch '^[A-Za-z0-9._-]+$') {
            throw "$($pair.n) содержит недопустимые символы: '$($pair.v)'. Допустимы A-Z a-z 0-9 . _ -"
        }
    }

    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $Destination = (Resolve-Path -LiteralPath $Destination).Path

    $projectDir = Join-Path $Destination $ProjectName
    if (Test-Path -LiteralPath $projectDir) {
        throw "Каталог уже существует: $projectDir"
    }

    $routerHostsDir = Join-Path $Destination 'router\config\nginx_hosts'
    if (-not (Test-Path -LiteralPath $routerHostsDir -PathType Container)) {
        throw "Каталог конфигов роутера не найден: $routerHostsDir. Сначала разверните роутер."
    }

    $profiles = New-Object System.Collections.Generic.List[string]

    # --- backend --------------------------------------------------------------
    $useBackend = if ($PSBoundParameters.ContainsKey('Backend')) { [bool]$Backend } else { Read-YesNo 'Нужен backend?' }
    if ($useBackend) {
        $profiles.Add('backend')
        if (-not $PSBoundParameters.ContainsKey('XdebugPort')) {
            $XdebugPort = Read-Port -Prompt 'Порт XDebug (для настроек IDE)' -Default $XdebugPort
        }
    }

    # --- frontend -------------------------------------------------------------
    $useFrontend = if ($PSBoundParameters.ContainsKey('Frontend')) { [bool]$Frontend } else { Read-YesNo 'Нужен frontend?' }
    if ($useFrontend) {
        $profiles.Add('frontend')
        if (-not $PSBoundParameters.ContainsKey('NodePort')) {
            $NodePort = Read-Port -Prompt 'Внешний порт контейнера node' -Default $NodePort
        }
    }

    # --- storage --------------------------------------------------------------
    if (-not $Database) {
        if (Read-YesNo 'Нужно хранилище?') {
            Write-Host 'Выберите базу данных:'
            Write-Host '  1 - PostgreSQL (по умолчанию)'
            Write-Host '  2 - MariaDB'
            $choice = Read-Value -Prompt 'Ваш выбор (1/2)' -Default '1' -Pattern '^[12]$' `
                -PatternMessage 'Введите 1 или 2.'
            $Database = if ($choice -eq '2') { 'mariadb' } else { 'postgres' }
        }
        else {
            $Database = 'none'
        }
    }

    $dbDockerfile   = 'postgres.dockerfile'
    $dbDataVolume   = './data/postgres:/var/lib/postgresql/data/pgdata'
    $dbPortInternal = 5432
    $dbCommand      = 'postgres'
    $dbDefaultPort  = 5432

    if ($Database -eq 'mariadb') {
        $dbDockerfile   = 'mariadb.dockerfile'
        $dbDataVolume   = './data/mysql:/var/lib/mysql'
        $dbPortInternal = 3306
        $dbCommand      = 'mysqld'
        $dbDefaultPort  = 3306
    }

    if ($Database -ne 'none') {
        $profiles.Add('storage')
        if (-not $PSBoundParameters.ContainsKey('DbPort')) {
            $DbPort = Read-Port -Prompt 'Внешний порт базы данных' -Default $dbDefaultPort
        }
    }
    elseif (-not $PSBoundParameters.ContainsKey('DbPort')) {
        $DbPort = $dbDefaultPort
    }

    $profilesString = $profiles -join ','
    $fqdn = "$ProjectName.$ProjectDomain"

    Write-Host ''
    Write-Host "Profiles: $(if ($profilesString) { $profilesString } else { '<none>' })"
    Write-Host "Your project is $fqdn"
    Write-Host "Folder $projectDir will be created"
    Wait-Key

    # --- клонирование ---------------------------------------------------------
    Set-Step "git clone $RepoUrl"
    Invoke-Native git @('clone', '--', $RepoUrl, $projectDir)
    Push-Location -LiteralPath $projectDir
    try {
        # --- .env -------------------------------------------------------------
        Set-Step 'подстановка параметров в .env'
        Set-Placeholders -Path '.env' -Map @{
            COMPOSE_PROFILES   = $profilesString
            ENV_STAGE          = $EnvStage
            PROJECT_NAME       = $ProjectName
            PROJECT_DOMAIN     = $ProjectDomain
            XDEBUG_REMOTE_PORT = $XdebugPort
            NODE_EXTERNAL_PORT = $NodePort
            DB_PORT            = $DbPort
            DB_PASSWORD        = $ProjectName
            DB_DOCKERFILE      = $dbDockerfile
            DB_DATA_VOLUME     = $dbDataVolume
            DB_PORT_INTERNAL   = $dbPortInternal
            DB_COMMAND         = $dbCommand
        }

        # --- php.ini ----------------------------------------------------------
        Set-Step 'подстановка параметров в php.ini'
        Set-Placeholders -Path 'config\php-ini\php.ini' -Map @{ XDEBUG_REMOTE_PORT = $XdebugPort }

        # --- nginx ------------------------------------------------------------
        Set-Step 'подстановка параметров в конфиги nginx'
        $locationFile = "${fqdn}_location"
        $vhostDir     = "config\nginx\vhost.d\$EnvStage"

        if (-not (Test-Path -LiteralPath $vhostDir -PathType Container)) {
            throw "Каталог vhost не найден: $vhostDir"
        }

        Copy-Item -LiteralPath 'dummy.domain_location' -Destination $locationFile -Force
        Set-Placeholders -Path $locationFile -Map @{ PROJECT_NAME = $ProjectName }

        Set-Placeholders -Path (Join-Path $vhostDir 'proxy.conf') -Map @{
            PROJECT_NAME   = $ProjectName
            PROJECT_DOMAIN = $ProjectDomain
        }

        $backendConf  = Join-Path $vhostDir 'modules\backend.conf'
        $frontendConf = Join-Path $vhostDir 'modules\frontend.conf'

        if ($useBackend) {
            Set-Placeholders -Path $backendConf -Map @{ PROJECT_NAME = $ProjectName }
        }
        else {
            Remove-ItemSafe $backendConf
        }
        if (-not $useFrontend) {
            Remove-ItemSafe $frontendConf
        }
        Write-Host 'Params copied to files'

        # --- конфиг роутеру ---------------------------------------------------
        Set-Step 'копирование конфига роутеру'
        Copy-Item -LiteralPath $locationFile -Destination (Join-Path $routerHostsDir $locationFile) -Force
        Write-Host 'Nginx config created and copied to router'
        Wait-Key

        Remove-ItemSafe 'data\mysql\.gitkeep'
        Remove-ItemSafe 'data\postgres\.gitkeep'

        # --- compose override -------------------------------------------------
        Set-Step 'выбор compose-файла для окружения'
        $stageCompose = "docker-compose.$EnvStage.yml"
        if (Test-Path -LiteralPath $stageCompose -PathType Leaf) {
            Copy-Item -LiteralPath $stageCompose -Destination 'docker-compose.override.yml' -Force
            Write-Host "Compose override for '$EnvStage' applied"
        }

        # --- docker -----------------------------------------------------------
        Set-Step 'docker compose up'
        $env:COMPOSE_PROFILES = $profilesString
        Invoke-Native docker @('compose', 'up', '-d')

        Set-Step "перезапуск $RouterName"
        Invoke-Native docker @('restart', $RouterName)
        Write-Host 'Main router restarted'
        Wait-Key

        # --- hosts ------------------------------------------------------------
        Set-Step 'обновление hosts'
        Add-HostsEntry -Fqdn $fqdn -Path $HostsFile
        Wait-Key

        # --- уборка -----------------------------------------------------------
        Set-Step 'уборка'
        Remove-ItemSafe $locationFile

        # конфиги nginx для неиспользуемых окружений
        Get-ChildItem -LiteralPath 'config\nginx\vhost.d' -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $EnvStage } |
            ForEach-Object { Remove-ItemSafe $_.FullName }

        # стадийные заготовки compose, остаётся только применённый override
        foreach ($stage in @('blank', 'dev', 'prod', 'test')) {
            Remove-ItemSafe "docker-compose.$stage.yml"
        }

        Remove-ItemSafe 'dummy.domain_location'
        if (-not $KeepSources) {
            Remove-ItemSafe '.gitignore'
            Remove-ItemSafe '.git'
            Remove-ItemSafe 'create_new_project.cmd'
            Remove-ItemSafe 'create_new_project.sh'
            Remove-ItemSafe 'create_new_project.ps1'
        }
        Write-Host 'Cleaned up' -ForegroundColor Green
    }
    finally {
        Pop-Location
    }

    Write-Host ''
    Write-Host "Готово: http://$fqdn" -ForegroundColor Green
    Wait-Key
    exit 0
}
catch {
    Write-Host ''
    Write-Host '=============== ОШИБКА ===============' -ForegroundColor Red
    Write-Host " шаг      : $script:Step"
    Write-Host " ошибка   : $($_.Exception.Message)"
    Write-Host " строка   : $($_.InvocationInfo.ScriptLineNumber)"
    Write-Host " команда  : $(($_.InvocationInfo.Line + '').Trim())"
    Write-Host " каталог  : $((Get-Location).Path)"
    Write-Host '======================================' -ForegroundColor Red
    Write-Host ''
    Write-Host 'Скрипт остановлен. Прочитайте сообщение выше.'
    Wait-Key 'Нажмите любую клавишу для выхода...'
    exit 1
}
finally {
    if ($Trace) {
        Set-PSDebug -Off
        if ($transcriptStarted) { Stop-Transcript | Out-Null }
    }
}
