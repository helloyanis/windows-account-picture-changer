<#
.SYNOPSIS
  Downloads PSexec if needed, then runs a PowerShell payload under SYSTEM (via PsExec -s).
.DESCRIPTION
  This payloads creates the key HKLM\...\AccountPicture\Users\<SID> & writes values ImageXXX.
  It allows you to use .png filew with transparency, .gif files, and other format of images as your account picture!
  Usually, Windows converts it to a .jpg file.
.NOTES
  - Run this as administrator.
  - PsExec is from Microsoft Sysinternals.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Parameters
# Get the user SID of the current user
$payloadSid = (New-Object System.Security.Principal.NTAccount($env:UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$imgPath = ''
$sizes = @('Image96','Image448','Image32','Image40','Image48','Image192','Image240','Image64','Image208','Image424','Image1080')

# PsExec path
$psToolsUrl = 'https://download.sysinternals.com/files/PSTools.zip'
$localToolsDir = Join-Path -Path $env:ProgramFiles -ChildPath 'PsTools'
$psexecPath = Join-Path -Path $localToolsDir -ChildPath 'PsExec.exe'

# Utility function : Checks if Psexec is present, downloads it otherwise. Psexec is needed in order to have write access to the registry key.
function Ensure-PsExec {
    param(
        [string]$Url,
        [string]$DestDir,
        [string]$PsexecExePath
    )
    if (Test-Path $PsexecExePath) {
        Write-Host "PsExec found : $PsexecExePath"
        return $true
    }

    Write-Host "PsExec not found. Downloading it..."
    $tmpZip = Join-Path $env:TEMP ('PSTools_' + [guid]::NewGuid().ToString() + '.zip')

    try {
        Invoke-WebRequest -Uri $Url -OutFile $tmpZip -UseBasicParsing -TimeoutSec 60
    } catch {
        Write-Error "Failed to download PsTools from $Url : $_"
        return $false
    }

    Write-Host "Extracting to $DestDir..."
    try {
        if (!(Test-Path $DestDir)) { New-Item -Path $DestDir -ItemType Directory | Out-Null }
        Expand-Archive -LiteralPath $tmpZip -DestinationPath $DestDir -Force
    } catch {
        Write-Error "Extraction failed : $_"
        Remove-Item -LiteralPath $tmpZip -ErrorAction SilentlyContinue
        return $false
    }

    Remove-Item -LiteralPath $tmpZip -ErrorAction SilentlyContinue

    if (Test-Path $PsexecExePath) {
        Write-Host "PsExec installed at $DestDir"
        return $true
    } else {
        Write-Error "PsExec could not be found after extracting it."
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
Write-Host "Checking execution rights..."
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Warning "This script must be run as an administrator."
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

Write-Host "Using image file : $imgPath for SID : $payloadSid , is this OK?" -ForegroundColor Cyan

Pause

# 1) Ensure PsExec
if (-not (Ensure-PsExec -Url $psToolsUrl -DestDir $localToolsDir -PsexecExePath $psexecPath)) {
    Write-Error "Could not seem to be able to use psexec."
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
$proc = Start-Process -FilePath $psexecPath -ArgumentList @('-accepteula','-s','-i','powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',$payloadFile) -Wait -PassThru

# Get the exit code
$exitCode = $proc.ExitCode
Write-Host "PsExec process finished with exit code : $exitCode"

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
} catch { }

Write-Host "Finished. Remember to disable account synchronization in Windows settings so the picture does not revert back to the one of your Microsoft account." -ForegroundColor Green
Write-Host "Log out or restart your computer to see the changes." -ForegroundColor Yellow
exit $exitCode