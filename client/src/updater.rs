//! Small companion updater for the installed Windows client.
//!
//! The updater intentionally lives in a separate process: an installer cannot
//! reliably replace the running client executable. It uses the PowerShell that
//! ships with supported Windows versions for HTTPS and JSON handling, verifies
//! the downloaded setup executable against the release SHA-256 asset, then
//! starts the installer and exits so the installer owns the replacement.

#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
use std::ffi::OsStr;
#[cfg(windows)]
use std::fs;
#[cfg(windows)]
use std::os::windows::ffi::OsStrExt;
#[cfg(windows)]
use std::os::windows::process::CommandExt;
#[cfg(windows)]
use std::process::Command;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
#[cfg(windows)]
const MB_OK: u32 = 0x0000_0000;
#[cfg(windows)]
const MB_ICONERROR: u32 = 0x0000_0010;

#[cfg(windows)]
const UPDATE_SCRIPT: &str = r#"
param([Parameter(Mandatory=$true)][string]$CurrentVersion)
$ErrorActionPreference = 'Stop'
$null = Add-Type -AssemblyName System.Windows.Forms
$repo = 'aydinmrnv/transom'
$headers = @{ 'User-Agent' = 'Transom-Updater'; 'Accept' = 'application/vnd.github+json' }

try {
    $releases = @(Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri "https://api.github.com/repos/$repo/releases?per_page=20")
    $release = @($releases |
        Where-Object {
            $_.draft -eq $false -and
            @($_.assets | Where-Object { $_.name -like 'TransomSetup-v*.exe' }).Count -gt 0
        } |
        Sort-Object { [version](($_.tag_name -replace '^v', '')) } -Descending)[0]

    if ($null -eq $release) {
        throw 'No Windows installer release is currently available.'
    }

    $latestVersion = ($release.tag_name -replace '^v', '')
    try {
        $isNewer = ([version]$latestVersion -gt [version]$CurrentVersion)
    } catch {
        throw "The release version '$latestVersion' is not a valid Windows version."
    }

    if (-not $isNewer) {
        [System.Windows.Forms.MessageBox]::Show(
            "Transom $CurrentVersion is up to date.",
            'Transom',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        exit 0
    }

    $installerAsset = @($release.assets | Where-Object { $_.name -like 'TransomSetup-v*.exe' })[0]
    $checksumAsset = @($release.assets | Where-Object { $_.name -eq "Transom-Windows-$($release.tag_name)-SHA256SUMS.txt" })[0]
    if ($null -eq $checksumAsset) {
        throw "Release $($release.tag_name) does not include a checksum file."
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Transom $latestVersion is available. Download and install it now?",
        'Transom update available',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        exit 0
    }

    $installerPath = Join-Path $env:TEMP $installerAsset.name
    $checksumPath = Join-Path $env:TEMP $checksumAsset.name
    Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $installerAsset.browser_download_url -OutFile $installerPath
    Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $checksumAsset.browser_download_url -OutFile $checksumPath

    $expected = ((Select-String -Path $checksumPath -Pattern ("\s" + [regex]::Escape($installerAsset.name) + "$") | Select-Object -First 1).Line -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 -Path $installerPath).Hash.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($expected) -or $expected -ne $actual) {
        throw 'The downloaded installer failed its SHA-256 verification.'
    }

    [System.Windows.Forms.MessageBox]::Show(
        "The verified installer for Transom $latestVersion is ready. Transom will close and update now.",
        'Transom',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    Start-Process -FilePath $installerPath
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Transom could not check for updates:`n`n$($_.Exception.Message)",
        'Transom updater',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}
"#;

#[cfg(windows)]
fn main() {
    let current_version = argument_value("--current-version")
        .unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_string());

    let script_path =
        std::env::temp_dir().join(format!("transom-updater-{}.ps1", std::process::id()));
    if let Err(error) = fs::write(&script_path, UPDATE_SCRIPT) {
        show_error(&format!("Transom could not prepare its updater: {error}"));
        return;
    }

    let status = Command::new("powershell.exe")
        .creation_flags(CREATE_NO_WINDOW)
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
        ])
        .arg(&script_path)
        .args(["-CurrentVersion"])
        .arg(&current_version)
        .status();
    let _ = fs::remove_file(script_path);

    if status.map(|result| !result.success()).unwrap_or(true) {
        show_error("Transom could not complete its update check.");
    }
}

#[cfg(windows)]
fn argument_value(name: &str) -> Option<String> {
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == name {
            return args.next();
        }
    }
    None
}

#[cfg(windows)]
fn show_error(message: &str) {
    let title = wide("Transom updater");
    let body = wide(message);
    unsafe {
        let _ = MessageBoxW(
            std::ptr::null_mut(),
            body.as_ptr(),
            title.as_ptr(),
            MB_OK | MB_ICONERROR,
        );
    }
}

#[cfg(windows)]
fn wide(value: &str) -> Vec<u16> {
    OsStr::new(value)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

#[cfg(windows)]
#[link(name = "user32")]
extern "system" {
    fn MessageBoxW(
        hwnd: *mut std::ffi::c_void,
        text: *const u16,
        caption: *const u16,
        typ: u32,
    ) -> i32;
}

#[cfg(not(windows))]
fn main() {
    eprintln!("transom-updater only runs on Windows");
}
