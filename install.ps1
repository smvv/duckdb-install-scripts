<#
DuckDB Windows installer script, revision $Id$
Issues/PRs for this script: https://github.com/duckdb/duckdb-install-scripts
#>

$ErrorActionPreference = "Stop"

$install_value = $env:DUCKDB_INSTALL
if ([string]::IsNullOrEmpty($install_value)) {
    $install_value = "cli"
}

$install_components = $install_value.Split([char]',')
foreach ($component in $install_components) {
    if (@("cli", "static", "shared") -cnotcontains $component) {
        throw "Invalid DUCKDB_INSTALL component '${component}'. Expected cli, static, or shared."
    }
}

$install_cli = $install_components -ccontains "cli"
$install_static = $install_components -ccontains "static"
$install_shared = $install_components -ccontains "shared"

$duckdb_staged = $env:DUCKDB_STAGED
$requested_version = $env:DUCKDB_VERSION

if (-not $duckdb_staged -and $requested_version -eq "alpha") {
    $duckdb_staged = (iwr "https://duckdb-staging.duckdb.org/latest_alpha_version.txt").Content.Trim()
}

if ($duckdb_staged) {
    $staged_parts = $duckdb_staged.Split('/')
    $staged_commit = $staged_parts[0]
    if ($staged_commit.Length -gt 10) {
        $staged_commit = $staged_commit.Substring(0, 10)
    }
    if ($duckdb_staged.Contains('/')) {
        $duckdb_version = $staged_parts[1]
    } else {
        $duckdb_version = (iwr "https://duckdb-staging.duckdb.org/${staged_commit}/latest_alpha_version.txt").Content.Trim()
    }
    $duckdb_staged = "${staged_commit}/${duckdb_version}"
} elseif ($requested_version) {
    $duckdb_version = $requested_version
} else {
    $duckdb_version = (iwr "https://duckdb.org/data/latest_stable_version.txt").Content.Trim()
}

if (-not $duckdb_staged -and $duckdb_version.StartsWith("v")) {
    $duckdb_version = $duckdb_version.Substring(1)
}

if (($install_static -or $install_shared) -and ($duckdb_version -like "1*" -or $duckdb_version -like "v1*")) {
    throw "static/shared libraries require DuckDB >= 2.0"
}

$expected_duckdb_version = $duckdb_version
if (-not $expected_duckdb_version.StartsWith("v")) {
    $expected_duckdb_version = "v${expected_duckdb_version}"
}

$path_version = $duckdb_version
if ($path_version.StartsWith("v")) {
    $path_version = $path_version.Substring(1)
}

$duckdb_arch = ''
$arch = (Get-CimInstance Win32_operatingsystem).OSArchitecture
if ($arch -eq '64-bit') {
    $duckdb_arch = 'windows-amd64'
}
if ($arch -eq 'ARM 64-bit Processor') {
    $duckdb_arch = 'windows-arm64'
}
if ($duckdb_arch -eq '') {
    throw "Architecture ${arch} is not supported. Sorry."
}

$duckdb_root = Join-Path $env:LOCALAPPDATA -ChildPath "duckdb"
$cli_path = Join-Path $duckdb_root -ChildPath "cli"
$local_install_dir = Join-Path $cli_path -ChildPath $path_version
$duckdb_exec = Join-Path $local_install_dir -ChildPath "duckdb.exe"
$library_path = Join-Path $duckdb_root -ChildPath "lib"
$library_install_dir = Join-Path $library_path -ChildPath $path_version

Write-Host
Write-Host "*** DuckDB Windows installation script, version ${duckdb_version} ***"
Write-Host
Write-Host
Write-Host "         .;odxdl,            "
Write-Host "       .xXXXXXXXXKc          "
Write-Host "       0XXXXXXXXXXXd  cooo:  "
Write-Host "      ,XXXXXXXXXXXXK  OXXXXd "
Write-Host "       0XXXXXXXXXXXo  cooo:  "
Write-Host "       .xXXXXXXXXKc          "
Write-Host "         .;odxdl,  "
Write-Host
Write-Host

function TestDuckDB {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Path
    )

    $duckdb_output = & $Path -noheader -init NUL -csv -batch -s "SELECT version()"
    if ($duckdb_output -ne $expected_duckdb_version) {
        throw "Version mismatch, ${duckdb_version} vs. ${duckdb_output}"
    }
}

function TestNonEmptyFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Path
    )

    if (-not (Test-Path $Path -PathType Leaf)) {
        return $false
    }
    return (Get-Item $Path).Length -gt 0
}

function ExtractCliV1 {
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $DestinationPath
    )

    $download_url = "https://install.duckdb.org/v${duckdb_version}/duckdb_cli-${duckdb_arch}.zip"
    $archive_file = Join-Path $DestinationPath "duckdb.zip"
    Invoke-WebRequest $download_url -OutFile $archive_file
    Microsoft.PowerShell.Archive\Expand-Archive -Path $archive_file -DestinationPath $DestinationPath -Force
}

function ExtractCliV2 {
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $DestinationPath
    )

    if ($duckdb_staged) {
        $download_url = "https://duckdb-staging.duckdb.org/${duckdb_staged}/duckdb/duckdb/github_release/duckdb-cli-${duckdb_arch}.tar.gz"
    } else {
        $download_url = "https://install.duckdb.org/v${duckdb_version}/duckdb-cli-${duckdb_arch}.tar.gz"
    }
    $archive_file = Join-Path $DestinationPath "duckdb-cli.tar.gz"
    Invoke-WebRequest $download_url -OutFile $archive_file
    tar.exe -xzf $archive_file -C $DestinationPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to unpack DuckDB CLI"
    }
}

function GetLibraryUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Component
    )

    if ($duckdb_staged) {
        return "https://duckdb-staging.duckdb.org/${duckdb_staged}/duckdb/duckdb/github_release/duckdb-${Component}-libs-${duckdb_arch}.tar.gz"
    }
    return "https://install.duckdb.org/v${duckdb_version}/duckdb-${Component}-libs-${duckdb_arch}.tar.gz"
}

function TestLibraryInstalled {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]
        $RequiredFiles
    )

    foreach ($required_file in $RequiredFiles) {
        if (-not (TestNonEmptyFile (Join-Path $library_install_dir -ChildPath $required_file))) {
            return $false
        }
    }
    return $true
}

function ExtractLibrary {
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Component,

        [Parameter(Mandatory = $true)]
        [string[]]
        $RequiredFiles,

        [Parameter(Mandatory = $true)]
        [string]
        $DestinationPath,

        [Parameter(Mandatory = $true)]
        [string]
        $TempRoot
    )

    $archive_file = Join-Path $TempRoot -ChildPath "duckdb-${Component}-libs.tar.gz"
    $download_url = GetLibraryUrl $Component
    Invoke-WebRequest $download_url -OutFile $archive_file
    tar.exe -xzf $archive_file -C $DestinationPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to unpack DuckDB ${Component} library"
    }

    foreach ($required_file in $RequiredFiles) {
        $candidate = Join-Path $DestinationPath -ChildPath $required_file
        if (-not (TestNonEmptyFile $candidate)) {
            throw "The ${Component} library archive did not contain ${required_file}."
        }
    }
}

function InstallLibraries {
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $TempRoot
    )

    $static_files = @("duckdb.h", "duckdb_static.lib")
    $shared_files = @("duckdb.h", "duckdb.dll", "duckdb.lib")
    $need_static = $install_static -and -not (TestLibraryInstalled $static_files)
    $need_shared = $install_shared -and -not (TestLibraryInstalled $shared_files)

    if ($install_static -and -not $need_static) {
        Write-Host "DuckDB static library already exists in ${library_install_dir}"
    }
    if ($install_shared -and -not $need_shared) {
        Write-Host "DuckDB shared library already exists in ${library_install_dir}"
    }
    if (-not $need_static -and -not $need_shared) {
        return
    }

    $null = New-Item -Path $library_path -ItemType Directory -Force
    $library_random = [System.IO.Path]::GetRandomFileName()
    $library_stage = Join-Path $library_path -ChildPath ".${path_version}.${library_random}.tmp"
    $library_backup = Join-Path $library_path -ChildPath ".${path_version}.${library_random}.previous"

    try {
        $null = New-Item -Path $library_stage -ItemType Directory
        if (Test-Path $library_install_dir -PathType Container) {
            Get-ChildItem -LiteralPath $library_install_dir -Force | Copy-Item -Destination $library_stage -Recurse -Force
        } elseif (Test-Path $library_install_dir) {
            throw "Library install destination ${library_install_dir} exists and is not a directory."
        }

        if ($need_static) {
            ExtractLibrary "static" $static_files $library_stage $TempRoot
        }
        if ($need_shared) {
            ExtractLibrary "shared" $shared_files $library_stage $TempRoot
        }

        if (Test-Path $library_install_dir -PathType Container) {
            Move-Item -LiteralPath $library_install_dir -Destination $library_backup
        }
        try {
            Move-Item -LiteralPath $library_stage -Destination $library_install_dir
        } catch {
            if ((Test-Path $library_backup -PathType Container) -and -not (Test-Path $library_install_dir)) {
                Move-Item -LiteralPath $library_backup -Destination $library_install_dir
            }
            throw
        }

        if (Test-Path $library_backup -PathType Container) {
            Remove-Item -LiteralPath $library_backup -Recurse -Force
        }

        if ($need_static) {
            Write-Host "Successfully installed DuckDB static library to ${library_install_dir}"
        }
        if ($need_shared) {
            Write-Host "Successfully installed DuckDB shared library to ${library_install_dir}"
        }
    } finally {
        if (Test-Path $library_stage -PathType Container) {
            Remove-Item -LiteralPath $library_stage -Recurse -Force
        }
        if (Test-Path $library_backup -PathType Container) {
            if (-not (Test-Path $library_install_dir)) {
                Move-Item -LiteralPath $library_backup -Destination $library_install_dir
            } else {
                Remove-Item -LiteralPath $library_backup -Recurse -Force
            }
        }
    }
}

if (-not $env:TEMP) {
    $env:TEMP = Join-Path $env:SystemDrive -ChildPath 'temp'
}
$random_path_ele = [System.IO.Path]::GetRandomFileName()
$temp_dir = Join-Path $env:TEMP -ChildPath "duckdb_install_${random_path_ele}"
$null = New-Item -Path $temp_dir -ItemType Directory -Force

try {
    if ($install_cli) {
        $null = New-Item -Path $local_install_dir -ItemType Directory -Force

        if (Test-Path $duckdb_exec -PathType Leaf) {
            TestDuckDB $duckdb_exec
            Write-Host "Destination binary ${duckdb_exec} already exists and seems to work."
        } else {
            $cli_temp = Join-Path $temp_dir -ChildPath "cli"
            $null = New-Item -Path $cli_temp -ItemType Directory -Force
            if (-not $duckdb_staged -and "${duckdb_version}" -like "1*") {
                ExtractCliV1 $cli_temp
            } else {
                ExtractCliV2 $cli_temp
            }

            $duckdb_exec_candidate = Join-Path $cli_temp -ChildPath "duckdb.exe"
            if (-not (Test-Path $duckdb_exec_candidate -PathType Leaf)) {
                throw "Failed to download and/or unpack DuckDB CLI"
            }
            TestDuckDB $duckdb_exec_candidate

            Write-Host "Installing to ${local_install_dir}"
            Copy-Item -Path $duckdb_exec_candidate -Destination $duckdb_exec -Force
            if (-not (Test-Path $duckdb_exec -PathType Leaf)) {
                throw "Failed to install DuckDB CLI"
            }
            TestDuckDB $duckdb_exec
            Write-Host "Successfully installed DuckDB binary to ${duckdb_exec}"
        }
    }

    if ($install_static -or $install_shared) {
        InstallLibraries $temp_dir
    }
} finally {
    if (Test-Path $temp_dir -PathType Container) {
        Remove-Item -LiteralPath $temp_dir -Recurse -Force
    }
}

if ($install_static -or $install_shared) {
    Write-Host
    Write-Host "DuckDB C/C++ headers and libraries are installed in ${library_install_dir}"
    Write-Host "Compile with /I `"${library_install_dir}`" and /LIBPATH:`"${library_install_dir}`"."
}

if ($install_cli) {
    Write-Host
    Write-Host "To launch DuckDB now, type"
    Write-Host "${duckdb_exec}"

    try {
        $WshShell = New-Object -COMObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut("$Home\Desktop\DuckDB.lnk")
        $Shortcut.TargetPath = ${duckdb_exec}
        $Shortcut.Save()
        Write-Host "There should also be a shortcut on your Desktop now."
    } catch {
    }
}
