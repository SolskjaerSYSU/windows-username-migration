# Redirects per-user font registrations (HKCU Fonts) that still point into the OLD profile folder.
# The font FILES usually moved together with the profile - only the registry paths are stale,
# so no reinstall is needed: repoint the values and broadcast WM_FONTCHANGE.
# HKCU only - no admin required.
# Usage: .\fonts_fix.ps1 -OldProfilePath "C:\Users\OldName"
param(
  [Parameter(Mandatory=$true)][string]$OldProfilePath,   # e.g. "C:\Users\OldName" (no trailing backslash)
  [string]$NewFontsDir = "$env:USERPROFILE\AppData\Local\Microsoft\Windows\Fonts",
  [string]$BackupDir = "$env:USERPROFILE\Desktop\fonts_reg_baks"
)
$ErrorActionPreference = 'Continue'
$fontsKeyPath = 'Software\Microsoft\Windows NT\CurrentVersion\Fonts'
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
& reg.exe export "HKCU\$fontsKeyPath" (Join-Path $BackupDir 'HKCU_Fonts.reg') /y 2>$null | Out-Null

$k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($fontsKeyPath, $true)
if (-not $k) { Write-Output 'Fonts key not found.'; exit 1 }
$fixed = 0; $missing = 0
foreach ($vn in $k.GetValueNames()) {
  $v = $k.GetValue($vn, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  if (-not "$v" -or -not "$v".StartsWith($OldProfilePath, [StringComparison]::OrdinalIgnoreCase)) { continue }
  $fileName = [IO.Path]::GetFileName("$v")
  $candidate = Join-Path $NewFontsDir $fileName
  if (Test-Path -LiteralPath $candidate) {
    $kind = $k.GetValueKind($vn)
    $k.SetValue($vn, $candidate, $kind)
    Write-Output ("FIXED: " + $vn + " -> " + $candidate)
    $fixed++
  } else {
    Write-Output ("MISSING (file not in new Fonts dir - copy it there or reinstall): " + $fileName)
    $missing++
  }
}
$k.Close()
Write-Output ("fixed: " + $fixed + ", missing: " + $missing)

# Broadcast WM_FONTCHANGE so running apps pick up the change without a reboot.
$sig = '[DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
$type = Add-Type -MemberDefinition $sig -Name 'Win32SendMessage' -Namespace 'Win32' -PassThru
$result = [UIntPtr]::Zero
$null = $type::SendMessageTimeout([IntPtr]0xFFFF, 0x001D, [UIntPtr]::Zero, $null, 2, 1000, [ref]$result)
Write-Output 'WM_FONTCHANGE broadcast sent.'
