<#
.SYNOPSIS
    Validates local PsExec and runs a PowerShell payload under SYSTEM (via PsExec -s).
.DESCRIPTION
    PsExec must already be installed locally at Program Files\SysinternalsSuite\PsExec.exe.
    If missing, the script redirects to the official Sysinternals download documentation page.
  This payloads creates the key HKLM\...\AccountPicture\Users\<SID> & writes values ImageXXX.
  It allows you to use .png filew with transparency, .gif files, and other format of images as your account picture!
  Usually, Windows converts it to a .jpg file.
.EXAMPLE
    .\account-picture-changer.ps1
    Runs the script as admin and opens an image picker dialog.

.EXAMPLE
    .\account-picture-changer.ps1 -ImagePath "C:\Users\<YourUser>\Pictures\avatar.png"
    Runs the script as admin and uses the provided local image path directly.
.NOTES
  - Run this as administrator.
  - PsExec is from Microsoft Sysinternals.
#>

param(
        [string]$ImagePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedPsExecSha256 = '078163D5C16F64CAA5A14784323FD51451B8C831C73396B967B4E35E6879937B' # for version 2.43.0.0
# TODO: Need a better way to handle hash changes with Sysinternal version updates. 
$sysinternalsDownloadPage = 'https://learn.microsoft.com/en-us/sysinternals/downloads/'
$auditLogDir = Join-Path -Path $env:ProgramData -ChildPath 'AccountPictureScript'
$auditLogPath = Join-Path -Path $auditLogDir -ChildPath 'account-picture-changer.log'

# Parameters
# Get the user SID of the current user
$payloadSid = (New-Object System.Security.Principal.NTAccount($env:UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$imgPath = $ImagePath
$sizes = @('Image96','Image448','Image32','Image40','Image48','Image192','Image240','Image64','Image208','Image424','Image1080')

# PsExec path
$localToolsDir = Join-Path -Path $env:ProgramFiles -ChildPath 'SysinternalsSuite'
$psexecPath = Join-Path -Path $localToolsDir -ChildPath 'PsExec.exe'

function Write-AuditLog {
    param(
        [string]$Message
    )

    if (-not (Test-Path -LiteralPath $auditLogDir)) {
        New-Item -Path $auditLogDir -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $auditLogPath -Value "[$timestamp] $Message"
}

function Test-ImagePathSecurity {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Warning "Image path is empty."
        return $false
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Warning "Image file does not exist: $Path"
        return $false
    }

    if ($Path -match '^[\\]{2}') {
        Write-Warning "UNC/network paths are not allowed for image selection: $Path"
        return $false
    }

    $allowedExt = @('.png', '.jpg', '.jpeg', '.bmp', '.gif')
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($allowedExt -notcontains $ext) {
        Write-Warning "Unsupported image extension '$ext'. Allowed: $($allowedExt -join ', ')"
        return $false
    }

    try {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
        $root = [System.IO.Path]::GetPathRoot($resolved.Path)
        if ([string]::IsNullOrWhiteSpace($root)) {
            Write-Warning "Could not determine drive root for image path: $Path"
            return $false
        }

        $driveLetter = $root.TrimEnd('\\').TrimEnd(':')
        $driveDeviceId = '{0}:' -f $driveLetter
        $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$driveDeviceId'"
        if ($null -eq $drive) {
            Write-Warning "Could not verify drive type for image path: $Path"
            return $false
        }

        # 3 = local fixed disk
        if ($drive.DriveType -ne 3) {
            Write-Warning "Image must be on a local fixed disk. Current drive type: $($drive.DriveType)"
            return $false
        }
    } catch {
        Write-Warning "Failed to validate image path security constraints: $_"
        return $false
    }

    return $true
}

# Utility function : Checks if Psexec is present and validates hash.
function Ensure-PsExec {
    param(
        [string]$PsexecExePath,
        [string]$ExpectedSha256,
        [string]$DownloadInfoUrl
    )
    if (-not (Test-Path -LiteralPath $PsexecExePath)) {
        Write-Warning "PsExec not found at expected path: $PsexecExePath"
        Write-Warning "Download Sysinternals tools from: $DownloadInfoUrl"
        Write-AuditLog "PsExec missing at expected path. User directed to official download page."
        return $false
    }

    try {
        $actualHash = (Get-FileHash -LiteralPath $PsexecExePath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualHash -ne $ExpectedSha256.ToUpperInvariant()) {
            Write-Error "PsExec hash mismatch. Expected: $ExpectedSha256, Actual: $actualHash"
            Write-AuditLog "PsExec hash validation failed. Expected=$ExpectedSha256 Actual=$actualHash"
            return $false
        }

        Write-Host "PsExec hash validated."
        Write-AuditLog "PsExec hash validation succeeded. Hash=$actualHash"
        return $true
    } catch {
        Write-Error "Failed to validate PsExec hash: $_"
        Write-AuditLog "PsExec hash validation failed due to error: $_"
        return $false
    }
}

# Utility function : Creates the payload that will be ran under SYSTEM
function New-PayloadScript {
    param(
        [string]$TargetSid,
        [string]$ImageFullPath,
        [string[]]$SizeNames
    )
    $payloadPath = Join-Path $env:TEMP ('payload_write_accountpic_' + [guid]::NewGuid().ToString() + '.ps1')

    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\$TargetSid"

    $sb = [System.Text.StringBuilder]::new()
    $sb.AppendLine("# Payload ran under SYSTEM from the account picture changer script") | Out-Null
    $sb.AppendLine("Set-StrictMode -Version Latest") | Out-Null
    $sb.AppendLine('$ErrorActionPreference = "Stop"') | Out-Null
    $sb.AppendLine("") | Out-Null
    $sb.AppendLine("try {") | Out-Null
    $sb.AppendLine("    # Creates the key if it's absent (Should never happen, but better safe than sorry)") | Out-Null
    $sb.AppendLine("    if (-not (Test-Path '$regPath')) { New-Item -Path '$regPath' -Force | Out-Null }") | Out-Null
    $sb.AppendLine("") | Out-Null

    foreach ($n in $SizeNames) {
        # Escape backslashes for registry literal in string
        $escapedImg = $ImageFullPath -replace '\\','\\'
        # Write image changes in the payload
        $sb.AppendLine("    New-ItemProperty -Path '$regPath' -Name '$n' -PropertyType String -Value '$escapedImg' -Force | Out-Null") | Out-Null
    }

    $sb.AppendLine("    Write-Host 'PAYLOAD: Finished writing properties.'") | Out-Null
    $sb.AppendLine("    exit 0") | Out-Null
    $sb.AppendLine("} catch {") | Out-Null
    $sb.AppendLine("    Write-Error 'PAYLOAD ERROR: ' + `$_.Exception.Message") | Out-Null
    $sb.AppendLine("    exit 1") | Out-Null
    $sb.AppendLine("}") | Out-Null

    $sb.ToString() | Out-File -FilePath $payloadPath -Encoding UTF8

    return $payloadPath
}

# Utility function : Open the file selection dialog to pick an image
function Select-ImageFile {
    Write-Host "Pick an image file for your account picture..."
    Add-Type -AssemblyName System.Windows.Forms
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title = "Select an image file for your account picture"
    $ofd.Filter = "Image Files|*.png;*.jpg;*.jpeg;*.bmp;*.gif|All Files|*.*"
    $ofd.InitialDirectory = [Environment]::GetFolderPath("MyPictures")
    $ofd.Multiselect = $false

    $result = $ofd.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $ofd.FileName
    } else {
        return $null
    }
}

# --- Main ---
Write-AuditLog "Script start. User=$env:UserName SID=$payloadSid"
Write-Host "Checking execution rights..."
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Warning "This script must be run as an administrator."
    Write-AuditLog "Script stopped: not running as administrator."
    exit 1
}

# If no image path provided, open file dialog
if ([string]::IsNullOrWhiteSpace($imgPath)) {
    $selectedFile = Select-ImageFile
    if ($null -eq $selectedFile) {
        Write-Warning "No image file selected. Exiting."
        exit 1
    } else {
        $imgPath = $selectedFile
    }
}

if (-not (Test-ImagePathSecurity -Path $imgPath)) {
    Write-Error "Image path failed security validation."
    Write-AuditLog "Script stopped: image path validation failed. Path=$imgPath"
    exit 1
}

Write-AuditLog "Image path validation passed. Path=$imgPath"

Write-Host "Using image file : $imgPath for SID : $payloadSid , is this OK?" -ForegroundColor Cyan

Pause

# 1) Ensure PsExec
if (-not (Ensure-PsExec -PsexecExePath $psexecPath -ExpectedSha256 $expectedPsExecSha256 -DownloadInfoUrl $sysinternalsDownloadPage)) {
    Write-Error "Could not seem to be able to use psexec."
    Write-AuditLog "Script stopped: PsExec validation failed."
    exit 1
}

# 2) Create the payload
$payloadFile = New-PayloadScript -TargetSid $payloadSid -ImageFullPath $imgPath -SizeNames $sizes
Write-Host "Payload created : $payloadFile"

# 3) Run the payload under SYSTEM (via PsExec -s)
#    -accepteula : Automatically accept the EULA (faster script)
#    -s : Execute under SYSTEM account
#    -i : interactive (optional).
#    Note : Starting Powershell as SYSTEM : The command will return the payload's exit code.

$psexecCmd = "`"$psexecPath`" -accepteula -s -i powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$payloadFile`""

Write-Host "Running the payload under SYSTEM via PsExec..."
Write-Host $psexecCmd
Write-Host "WARNING: This script uses PowerShell -ExecutionPolicy Bypass for the SYSTEM-run payload. Continue only if you trust this script and environment." -ForegroundColor Yellow
Write-AuditLog "Warning shown: ExecutionPolicy Bypass is in use for SYSTEM payload execution."
$proc = Start-Process -FilePath $psexecPath -ArgumentList @('-accepteula','-s','-i','powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',$payloadFile) -Wait -PassThru

# Get the exit code
$exitCode = $proc.ExitCode
Write-Host "PsExec process finished with exit code : $exitCode"
Write-AuditLog "PsExec execution finished. ExitCode=$exitCode Payload=$payloadFile"

# 4) Attempt to check if the values were changed correctly
try {
    $regCheckPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\$payloadSid"
    if (Test-Path $regCheckPath) {
        Write-Host "Key exists! Check if it corresponds to your image path." -ForegroundColor Green
        foreach ($n in $sizes) {
            $val = (Get-ItemProperty -Path $regCheckPath -Name $n -ErrorAction SilentlyContinue).$n
            if ($null -ne $val) {
                Write-Host "  $n = $val"
            } else {
                Write-Warning "  $n : Missing"
            }
        }
    } else {
        Write-Warning "Key $regCheckPath not found after execution."
    }
} catch {
    Write-Warning "Couldn't read registery keys for verification : $_"
}

# 5) Clean up payload
try {
    Remove-Item -LiteralPath $payloadFile -ErrorAction SilentlyContinue
    Write-AuditLog "Payload cleanup attempted. Path=$payloadFile"
} catch { }

Write-Host "Finished. Remember to disable account synchronization in Windows settings so the picture does not revert back to the one of your Microsoft account." -ForegroundColor Green
Write-Host "Log out or restart your computer to see the changes." -ForegroundColor Yellow
Write-AuditLog "Script end. ExitCode=$exitCode"
exit $exitCode
