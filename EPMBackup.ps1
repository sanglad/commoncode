<#
.SYNOPSIS
Creates a reusable Oracle Enterprise Performance Management (EPM) backup.

.DESCRIPTION
The script gathers Oracle EPM assets (LCM exports, Essbase data, file system
artifacts) into a timestamped package, compresses it, and enforces retention.
It is designed to be scheduled (e.g. Windows Task Scheduler) and offers
parameters for LCM credentials, Essbase exports, additional file paths, and
retention policies.

.EXAMPLE
PS> .\EPMBackup.ps1 -EpmHome "D:\Oracle\EPMSystem11R1" `
                    -BackupRoot "E:\Backups\EPM" `
                    -EnvironmentName "prod" `
                    -LcmBatchFile "D:\Oracle\Planning\Exports\ProdExport.xml" `
                    -LcmUrl "http://epmhost:19000/workspace" `
                    -LcmCredential (Get-Credential epmadmin)

.NOTES
Author: GPT-5 Codex
Compatible with: Windows PowerShell 5.1+ / PowerShell 7+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$EpmHome,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$BackupRoot,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$EnvironmentName = "prod",

    [Parameter()]
    [string]$OracleInstance = $env:EPM_ORACLE_INSTANCE,

    [Parameter()]
    [string[]]$PathsToBackup,

    [Parameter()]
    [int]$RetentionDays = 14,

    [Parameter()]
    [ValidateSet("NoCompression", "Fastest", "Optimal")]
    [string]$CompressionLevel = "Optimal",

    [Parameter()]
    [string]$LcmUtilityPath = "Utility.bat",

    [Parameter()]
    [string]$LcmBatchFile,

    [Parameter()]
    [uri]$LcmUrl,

    [Parameter()]
    [System.Management.Automation.PSCredential]$LcmCredential,

    [Parameter()]
    [string[]]$AdditionalLcmArguments,

    [Parameter()]
    [string]$EssbaseMaxlScript,

    [Parameter()]
    [string]$EssbaseUtilityPath = "startMaxl.bat",

    [switch]$SkipFileCopy,
    [switch]$SkipLcmExport,
    [switch]$SkipEssbaseExport,
    [switch]$KeepStagingFolder
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogFile = $null

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "{0} [{1}] {2}" -f $timestamp, $Level.ToUpper(), $Message
    Write-Host $entry
    if ($script:LogFile) {
        $entry | Out-File -FilePath $script:LogFile -Encoding utf8 -Append
    }
}

function Ensure-Directory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Creating directory: $Path" 'DEBUG'
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function ConvertTo-PlainText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Security.SecureString]$SecureString
    )

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Invoke-ExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter()]
        [string[]]$Arguments,

        [Parameter()]
        [string]$WorkingDirectory
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Executable not found: $FilePath"
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.WorkingDirectory = if ($WorkingDirectory) { $WorkingDirectory } else { Split-Path -LiteralPath $FilePath -Parent }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($Arguments) {
        $psi.Arguments = [string]::Join(' ', $Arguments)
    }

    Write-Log "Executing: $($psi.FileName) $($psi.Arguments)" 'INFO'

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($stdout) {
        foreach ($line in ($stdout -split "`r?`n")) {
            if ($line.Trim()) {
                Write-Log $line 'DEBUG'
            }
        }
    }

    if ($stderr) {
        foreach ($line in ($stderr -split "`r?`n")) {
            if ($line.Trim()) {
                Write-Log $line 'WARN'
            }
        }
    }

    if ($process.ExitCode -ne 0) {
        throw "Command failed with exit code $($process.ExitCode): $($psi.FileName)"
    }

    return $process.ExitCode
}

function Resolve-LcmUtility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EpmHome,

        [Parameter(Mandatory = $true)]
        [string]$LcmUtilityPath
    )

    if ([System.IO.Path]::IsPathRooted($LcmUtilityPath)) {
        if (Test-Path -LiteralPath $LcmUtilityPath) {
            return (Resolve-Path -LiteralPath $LcmUtilityPath).ProviderPath
        }
        throw "LCM utility not found at: $LcmUtilityPath"
    }

    $lcmRoot = Join-Path -Path $EpmHome -ChildPath "common\utilities"
    if (-not (Test-Path -LiteralPath $lcmRoot)) {
        throw "Unable to locate common utilities folder under: $EpmHome"
    }

    $leaf = Split-Path -Path $LcmUtilityPath -Leaf
    $candidate = Get-ChildItem -Path $lcmRoot -Filter $leaf -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($candidate) {
        return $candidate.FullName
    }

    throw "LCM utility named '$leaf' was not found under $lcmRoot"
}

function Resolve-EssbaseUtility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EpmHome,

        [Parameter(Mandatory = $true)]
        [string]$EssbaseUtilityPath
    )

    if ([System.IO.Path]::IsPathRooted($EssbaseUtilityPath)) {
        if (Test-Path -LiteralPath $EssbaseUtilityPath) {
            return (Resolve-Path -LiteralPath $EssbaseUtilityPath).ProviderPath
        }
        throw "Essbase utility not found at: $EssbaseUtilityPath"
    }

    $essbaseRoot = Join-Path -Path $EpmHome -ChildPath "products\Essbase\EssbaseServer\bin"
    if (-not (Test-Path -LiteralPath $essbaseRoot)) {
        throw "Unable to locate Essbase bin directory under: $EpmHome"
    }

    $leaf = Split-Path -Path $EssbaseUtilityPath -Leaf
    $candidate = Get-ChildItem -Path $essbaseRoot -Filter $leaf -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($candidate) {
        return $candidate.FullName
    }

    throw "Essbase utility named '$leaf' was not found under $essbaseRoot"
}

function Compress-Backup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$CompressionLevel
    )

    if (Test-Path -LiteralPath $ArchivePath) {
        Remove-Item -LiteralPath $ArchivePath -Force
    }

    Write-Log "Creating archive $ArchivePath" 'INFO'
    Compress-Archive -Path (Join-Path -Path $SourceDirectory -ChildPath '*') `
                     -DestinationPath $ArchivePath `
                     -CompressionLevel $CompressionLevel `
                     -Force
}

function Rotate-Backups {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupRoot,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $true)]
        [int]$RetentionDays
    )

    if ($RetentionDays -le 0) {
        Write-Log "Retention is disabled (RetentionDays <= 0)" 'INFO'
        return
    }

    $threshold = (Get-Date).AddDays(-$RetentionDays)
    Write-Log "Purging backups older than $RetentionDays days (before $threshold)" 'INFO'

    $archives = Get-ChildItem -Path $BackupRoot -Filter "$EnvironmentName-*.zip" -File -ErrorAction SilentlyContinue
    foreach ($archive in $archives) {
        if ($archive.LastWriteTime -lt $threshold) {
            Write-Log "Deleting expired archive: $($archive.FullName)" 'INFO'
            Remove-Item -LiteralPath $archive.FullName -Force
        }
    }

    $stagingDirs = Get-ChildItem -Path $BackupRoot -Directory -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -like "$EnvironmentName-*" }
    foreach ($dir in $stagingDirs) {
        if ($dir.LastWriteTime -lt $threshold) {
            Write-Log "Deleting expired staging folder: $($dir.FullName)" 'INFO'
            Remove-Item -LiteralPath $dir.FullName -Force -Recurse
        }
    }
}

Ensure-Directory -Path $BackupRoot
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$sessionName = "{0}-{1}" -f $EnvironmentName, $timestamp
$sessionRoot = Join-Path -Path $BackupRoot -ChildPath $sessionName
Ensure-Directory -Path $sessionRoot

$script:LogFile = Join-Path -Path $sessionRoot -ChildPath "backup.log"
Write-Log "Starting Oracle EPM backup for environment '$EnvironmentName'" 'INFO'
Write-Log "EPM home: $EpmHome" 'INFO'
Write-Log "Backup root: $BackupRoot" 'INFO'
Write-Log "Session folder: $sessionRoot" 'INFO'

try {
    if ($RetentionDays -lt 0) {
        throw "RetentionDays cannot be negative."
    }

    if (-not (Test-Path -LiteralPath $EpmHome)) {
        throw "EPM home not found: $EpmHome"
    }

    if (-not $PathsToBackup -or $PathsToBackup.Count -eq 0) {
        $defaultPaths = @()
        $defaultPaths += Join-Path -Path $EpmHome -ChildPath "user_projects"
        if ($OracleInstance) {
            $defaultPaths += Join-Path -Path $OracleInstance -ChildPath "diagnostics\logs"
        }
        $PathsToBackup = $defaultPaths
        Write-Log "Using default backup paths: $($PathsToBackup -join ', ')" 'INFO'
    }

    if (-not $SkipFileCopy) {
        $filesRoot = Join-Path -Path $sessionRoot -ChildPath "files"
        Ensure-Directory -Path $filesRoot

        foreach ($path in $PathsToBackup) {
            if (-not (Test-Path -LiteralPath $path)) {
                Write-Log "Skipping missing path: $path" 'WARN'
                continue
            }

            $targetName = Split-Path -Path $path -Leaf
            if (-not $targetName) {
                $targetName = $path.Replace(':', '').Replace('\', '_')
            }

            $destination = Join-Path -Path $filesRoot -ChildPath $targetName
            Ensure-Directory -Path $destination

            Write-Log "Copying $path to $destination via robocopy" 'INFO'
            $robocopyArgs = @(
                $path,
                $destination,
                "/MIR",
                "/R:3",
                "/W:5",
                "/Z",
                "/FFT",
                "/NFL",
                "/NDL",
                "/NP"
            )

            $robocopyOutput = & robocopy @robocopyArgs
            if ($robocopyOutput) {
                foreach ($line in ($robocopyOutput -split "`r?`n")) {
                    if ($line.Trim()) {
                        Write-Log $line 'DEBUG'
                    }
                }
            }

            $exitCode = $LASTEXITCODE
            if ($exitCode -gt 3) {
                throw "Robocopy reported failure ($exitCode) while copying $path"
            }
        }
    }
    else {
        Write-Log "Skipping filesystem copy as requested." 'INFO'
    }

    if (-not $SkipLcmExport) {
        if (-not $LcmBatchFile) {
            Write-Log "LCM batch file not provided; skipping LCM export." 'WARN'
        }
        else {
            $resolvedLcmBatch = (Resolve-Path -LiteralPath $LcmBatchFile -ErrorAction Stop).ProviderPath
            $lcmUtility = Resolve-LcmUtility -EpmHome $EpmHome -LcmUtilityPath $LcmUtilityPath
            $lcmOutputDir = Join-Path -Path $sessionRoot -ChildPath "lcm"
            Ensure-Directory -Path $lcmOutputDir
            $lcmLog = Join-Path -Path $lcmOutputDir -ChildPath "lcm.log"

            $lcmArgs = @("-b", "`"$resolvedLcmBatch`"", "-f", "`"$lcmLog`"")
            if ($LcmUrl) {
                $lcmArgs += @("-epmurl", "`"$($LcmUrl.AbsoluteUri)`"")
            }

            $plainPassword = $null
            if ($LcmCredential) {
                $plainPassword = ConvertTo-PlainText -SecureString $LcmCredential.Password
                $lcmArgs += @("-u", "`"$($LcmCredential.UserName)`"", "-p", "`"$plainPassword`"")
            }

            if ($AdditionalLcmArguments) {
                $lcmArgs += $AdditionalLcmArguments
            }

            try {
                Invoke-ExternalCommand -FilePath $lcmUtility -Arguments $lcmArgs -WorkingDirectory (Split-Path -Path $lcmUtility -Parent) | Out-Null
            }
            finally {
                if ($plainPassword) {
                    [System.Array]::Clear($plainPassword.ToCharArray(), 0, $plainPassword.Length)
                    $plainPassword = $null
                }
            }

            Write-Log "LCM export completed. Output in $lcmOutputDir" 'INFO'
        }
    }
    else {
        Write-Log "Skipping LCM export as requested." 'INFO'
    }

    if (-not $SkipEssbaseExport -and $EssbaseMaxlScript) {
        $resolvedMaxlScript = (Resolve-Path -LiteralPath $EssbaseMaxlScript -ErrorAction Stop).ProviderPath
        $essbaseUtility = Resolve-EssbaseUtility -EpmHome $EpmHome -EssbaseUtilityPath $EssbaseUtilityPath
        $essbaseOutput = Join-Path -Path $sessionRoot -ChildPath "essbase"
        Ensure-Directory -Path $essbaseOutput

        $essbaseArgs = @("`"$resolvedMaxlScript`"")
        Invoke-ExternalCommand -FilePath $essbaseUtility -Arguments $essbaseArgs -WorkingDirectory (Split-Path -Path $essbaseUtility -Parent) | Out-Null
        Write-Log "Essbase MAXL script executed. Review output under $essbaseOutput" 'INFO'
    }
    elseif ($EssbaseMaxlScript) {
        Write-Log "Essbase export skipped via flag." 'INFO'
    }

    $archivePath = Join-Path -Path $BackupRoot -ChildPath "$sessionName.zip"
    Compress-Backup -SourceDirectory $sessionRoot -ArchivePath $archivePath -CompressionLevel $CompressionLevel

    if (-not $KeepStagingFolder) {
        Write-Log "Cleaning staging folder $sessionRoot" 'DEBUG'
        Remove-Item -LiteralPath $sessionRoot -Force -Recurse
    }

    Rotate-Backups -BackupRoot $BackupRoot -EnvironmentName $EnvironmentName -RetentionDays $RetentionDays

    Write-Log "Backup complete. Archive: $archivePath" 'INFO'
}
catch {
    Write-Log "Backup failed: $_" 'ERROR'
    if ($_.ScriptStackTrace) {
        Write-Log $_.ScriptStackTrace 'DEBUG'
    }
    throw
}
