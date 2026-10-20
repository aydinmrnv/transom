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
use std::path::Path;
#[cfg(windows)]
use std::process::Command;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
#[cfg(windows)]
const MB_OK: u32 = 0x0000_0000;
#[cfg(windows)]
const MB_ICONERROR: u32 = 0x0000_0010;
/// The script already told the user what went wrong.
#[cfg(windows)]
const SCRIPT_REPORTED_FAILURE: i32 = 2;

#[cfg(windows)]
const UPDATE_SCRIPT: &str = r#"
param(
    [Parameter(Mandatory=$true)][string]$CurrentVersion,
    # Tests only: read the release list from this file, print the decision, and
    # exit without showing any UI.
    [string]$ReleasesFile
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Windows PowerShell 5.1 can still default to TLS 1.0, which GitHub refuses.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$null = Add-Type -AssemblyName System.Windows.Forms
$repo = 'aydinmrnv/transom'
$headers = @{ 'User-Agent' = 'Transom-Updater'; 'Accept' = 'application/vnd.github+json' }

function Get-ReleaseVersion($release) {
    $version = $null
    if ([version]::TryParse(($release.tag_name -replace '^v', ''), [ref]$version)) { $version }
}

function Show-Message(
    [string]$Text,
    [string]$Title,
    [System.Windows.Forms.MessageBoxButtons]$Buttons,
    [System.Windows.Forms.MessageBoxIcon]$Icon
) {
    # This process owns no window, so an unowned dialog can open behind Transom.
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
    try {
        [System.Windows.Forms.MessageBox]::Show([System.Windows.Forms.IWin32Window]$owner, $Text, $Title, $Buttons, $Icon)
    } finally {
        $owner.Dispose()
    }
}

try {
    # Assign, then pipe the variable: Windows PowerShell 5.1 emits a JSON array
    # as one object, and wrapping that in @() hides every release inside it.
    if ($ReleasesFile) {
        $releases = Get-Content -Raw -Path $ReleasesFile | ConvertFrom-Json
    } else {
        $releases = Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri "https://api.github.com/repos/$repo/releases?per_page=20"
    }
    $release = $releases |
        Where-Object {
            -not $_.draft -and
            $null -ne (Get-ReleaseVersion $_) -and
            @($_.assets | Where-Object { $_.name -like 'TransomSetup-v*.exe' }).Count -gt 0
        } |
        Sort-Object { Get-ReleaseVersion $_ } -Descending |
        Select-Object -First 1

    if ($null -eq $release) {
        throw 'No Windows installer release is currently available.'
    }

    $latestVersion = ($release.tag_name -replace '^v', '')
    $isNewer = ((Get-ReleaseVersion $release) -gt [version]$CurrentVersion)

    if ($ReleasesFile) {
        Write-Output ('{0} {1}' -f $release.tag_name, $(if ($isNewer) { 'newer' } else { 'current' }))
        exit 0
    }

    if (-not $isNewer) {
        Show-Message "Transom $CurrentVersion is up to date." 'Transom' 'OK' 'Information' | Out-Null
        exit 0
    }

    $installerAsset = @($release.assets | Where-Object { $_.name -like 'TransomSetup-v*.exe' })[0]
    $checksumAsset = @($release.assets | Where-Object { $_.name -eq "Transom-Windows-$($release.tag_name)-SHA256SUMS.txt" })[0]
    if ($null -eq $checksumAsset) {
        throw "Release $($release.tag_name) does not include a checksum file."
    }

    $answer = Show-Message "Transom $latestVersion is available. Download and install it now?" 'Transom update available' 'YesNo' 'Question'
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

    Show-Message "The verified installer for Transom $latestVersion is ready. Transom will close and update now." 'Transom' 'OK' 'Information' | Out-Null
    Start-Process -FilePath $installerPath
} catch {
    if ($ReleasesFile) { throw }
    Show-Message "Transom could not check for updates:`n`n$($_.Exception.Message)" 'Transom updater' 'OK' 'Error' | Out-Null
    exit 2
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

    let status = update_script(&script_path, &current_version)
        .creation_flags(CREATE_NO_WINDOW)
        .status();
    let _ = fs::remove_file(script_path);

    let reported =
        matches!(&status, Ok(s) if s.success() || s.code() == Some(SCRIPT_REPORTED_FAILURE));
    if !reported {
        show_error("Transom could not complete its update check.");
    }
}

/// Windows PowerShell 5.1 (`powershell.exe`), not `pwsh`: it is the one every
/// supported Windows ships, so its JSON quirks are the ones the script must survive.
#[cfg(windows)]
fn update_script(script_path: &Path, current_version: &str) -> Command {
    let mut command = Command::new("powershell.exe");
    command
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
        ])
        .arg(script_path)
        .arg("-CurrentVersion")
        .arg(current_version);
    command
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

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    const SETUP: &str = r#"{ "name": "TransomSetup-v0.0.0.exe" }"#;

    fn release(tag: &str, draft: bool, assets: &[&str]) -> String {
        format!(
            r#"{{ "tag_name": "{tag}", "draft": {draft}, "assets": [{}] }}"#,
            assets.join(", ")
        )
    }

    /// Runs the real script against a canned release list and returns what it
    /// decided, e.g. `v0.4.4 newer`.
    fn decide(name: &str, current_version: &str, releases: &[String]) -> String {
        let dir = std::env::temp_dir();
        let tag = format!("transom-updater-test-{}-{name}", std::process::id());
        let script_path = dir.join(format!("{tag}.ps1"));
        let releases_path = dir.join(format!("{tag}.json"));
        fs::write(&script_path, UPDATE_SCRIPT).unwrap();
        fs::write(&releases_path, format!("[{}]", releases.join(", "))).unwrap();

        let output = update_script(&script_path, current_version)
            .arg("-ReleasesFile")
            .arg(&releases_path)
            .output()
            .unwrap();
        let _ = fs::remove_file(script_path);
        let _ = fs::remove_file(releases_path);

        assert!(
            output.status.success(),
            "update script failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap().trim().to_string()
    }

    #[test]
    fn picks_the_newest_installer_release() {
        let releases = [
            release("v0.4.4", false, &[SETUP]),
            release("v0.10.0", true, &[SETUP]),
            release("v0.2.0", false, &[SETUP]),
            release("v0.1.0", false, &[]),
            release("nightly", false, &[SETUP]),
        ];
        assert_eq!(decide("newest", "0.2.0", &releases), "v0.4.4 newer");
        assert_eq!(decide("current", "0.4.4", &releases), "v0.4.4 current");
    }

    #[test]
    fn compares_versions_numerically() {
        let releases = [
            release("v0.9.0", false, &[SETUP]),
            release("v0.10.0", false, &[SETUP]),
        ];
        assert_eq!(decide("numeric", "0.9.0", &releases), "v0.10.0 newer");
    }

    #[test]
    fn handles_a_single_release() {
        let releases = [release("v0.4.4", false, &[SETUP])];
        assert_eq!(decide("single", "0.4.3", &releases), "v0.4.4 newer");
    }
}
