#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Enable dry run mode by setting this to $true
$DryRun = $false

# --- Logging --------------------------------------------------------------- #

function Write-Log {
    param(
        [string]$Message,
        [switch]$Important
    )
    $timestamp = Get-Date -Format "HH:mm:ss"
    if ($Important) {
        Write-Host "[$timestamp] $Message" -ForegroundColor Yellow
    } else {
        Write-Host "[$timestamp] $Message"
    }
}

# --- Stop Zen browser ------------------------------------------------------- #

function Stop-Zen {
    $zenProcs = Get-Process -Name "zen" -ErrorAction SilentlyContinue
    if ($zenProcs) {
        Write-Log "zen is running. Attempting to stop it gracefully."
        if ($DryRun) {
            Write-Log "Dry run enabled. Skipping stopping zen."
        } else {
            $zenProcs | Stop-Process -Force
            Start-Sleep -Seconds 5
        }
    } else {
        Write-Log "zen is not running."
    }
}

# --- Detect architecture ---------------------------------------------------- #

function Get-PlatformKey {
    if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) {
        $arch = "aarch64-msvc-aarch64"
    } else {
        $arch = "x86_64-msvc-x64"
    }
    Write-Log "Detected architecture: $arch"
    return "WINNT_$arch"
}

# --- Main ------------------------------------------------------------------- #

function Main {
    Write-Log "Starting Widevine CDM installation script."

    Stop-Zen

    $platformKey = Get-PlatformKey
    $profilesDir = Join-Path $env:APPDATA "zen\Profiles"

    $jsonUrl = "https://raw.githubusercontent.com/mozilla/gecko-dev/master/toolkit/content/gmp-sources/widevinecdm.json"

    Write-Log "Downloading and parsing JSON file from $jsonUrl."
    $jsonData = Invoke-RestMethod -Uri $jsonUrl

    $vendor = $jsonData.vendors.'gmp-widevinecdm'
    $platform = $vendor.platforms.$platformKey

    if (-not $platform) {
        Write-Log "No platform entry found for $platformKey. Exiting." -Important
        exit 1
    }

    # Check for alias and resolve if needed
    $resolvedKey = $platformKey
    if ($platform.alias) {
        Write-Log "Alias detected for $platformKey. Resolving to $($platform.alias)."
        $resolvedKey = $platform.alias
        $platform = $vendor.platforms.$resolvedKey
    }

    $zipUrl = $platform.fileUrl
    $version = $vendor.version

    Write-Log "Will download ZIP file from: $zipUrl"
    Write-Log "Widevine version: $version"

    $zipFile = Join-Path $env:TEMP "widevine-$(Get-Random).zip"

    if ($DryRun) {
        Write-Log "Dry run enabled. Skipping download of $zipUrl."
    } else {
        Write-Log "Downloading ZIP file to $zipFile."
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipFile -UseBasicParsing
    }

    Write-Log "Searching for profiles in $profilesDir."

    if (-not (Test-Path $profilesDir)) {
        Write-Log "Profiles directory not found: $profilesDir. Exiting." -Important
        Remove-Item -Path $zipFile -Force -ErrorAction SilentlyContinue
        exit 1
    }

    $profiles = Get-ChildItem -Path $profilesDir -Directory

    foreach ($profile in $profiles) {
        $targetDir = Join-Path $profile.FullName "gmp-widevinecdm\$version"

        # Clean out existing files
        if (Test-Path $targetDir) {
            Write-Log "Cleaning out existing files in $targetDir"
            if ($DryRun) {
                Write-Log "Dry run enabled. Skipping cleaning of $targetDir."
            } else {
                Remove-Item -Path "$targetDir\*" -Recurse -Force
            }
        }

        # Create directory
        Write-Log "Preparing to create directory: $targetDir"
        if ($DryRun) {
            Write-Log "Dry run enabled. Skipping directory creation."
        } else {
            if (-not (Test-Path $targetDir)) {
                Write-Log "Creating directory: $targetDir"
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            } else {
                Write-Log "Directory already exists: $targetDir"
            }
        }

        # Extract ZIP
        Write-Log "Preparing to extract ZIP to: $targetDir"
        if ($DryRun) {
            Write-Log "Dry run enabled. Skipping ZIP extraction."
        } else {
            Expand-Archive -Path $zipFile -DestinationPath $targetDir -Force
        }

        # Update user.js
        $userJs = Join-Path $profile.FullName "user.js"
        Write-Log "Preparing to update user.js at: $userJs"

        if ($DryRun) {
            Write-Log "Dry run enabled. Skipping user.js modification."
        } else {
            $prefs = @(
                "user_pref('media.gmp-widevinecdm.visible', true);"
                "user_pref('media.gmp-widevinecdm.enabled', true);"
                "user_pref('media.gmp-manager.url', 'https://aus5.mozilla.org/update/3/GMP/%VERSION%/%BUILD_ID%/%BUILD_TARGET%/%LOCALE%/%CHANNEL%/%OS_VERSION%/%DISTRIBUTION%/%DISTRIBUTION_VERSION%/update.xml');"
                "user_pref('media.gmp-provider.enabled', true);"
            )

            $existingContent = ""
            if (Test-Path $userJs) {
                $existingContent = Get-Content -Path $userJs -Raw -ErrorAction SilentlyContinue
                if (-not $existingContent) { $existingContent = "" }
            }

            foreach ($pref in $prefs) {
                if ($existingContent.Contains($pref)) {
                    continue
                }
                Write-Log "Adding preference: $pref"
                Add-Content -Path $userJs -Value $pref
            }

            if (Test-Path $userJs) {
                Write-Log "Preferences already exist or have been added to user.js."
            }
        }
    }

    # Clean up
    if ($DryRun) {
        Write-Log "Dry run enabled. Skipping ZIP file cleanup."
    } else {
        Write-Log "Cleaning up ZIP file: $zipFile"
        Remove-Item -Path $zipFile -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Widevine CDM installation script completed."
}

Main
