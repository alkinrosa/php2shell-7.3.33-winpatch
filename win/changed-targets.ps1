param(
	[Parameter(Mandatory = $true)][string]$Src,
	[Parameter(Mandatory = $true)][string]$BaseTag,
	[ValidateSet('changed', 'all')][string]$Scope = 'changed'
)

$ErrorActionPreference = 'Stop'
Set-Location $Src

# Shared extensions produced by this configuration (from the generated Makefile)
$makefile = Get-Content -Raw (Join-Path $Src 'Makefile')
if ($makefile -notmatch '(?m)^EXT_TARGETS=(.*)$') { throw 'EXT_TARGETS line not found in Makefile' }
$ignoredExt = @('php_zend_test.dll', 'php_phpdbg_webhelper.dll')
$shared = @($Matches[1].Trim() -split '\s+' | Where-Object { $_ -and ($ignoredExt -notcontains $_) })

$targets = New-Object System.Collections.Generic.List[string]
$report = New-Object System.Collections.Generic.List[string]
$coreHeaders = New-Object System.Collections.Generic.List[string]

function Add-Target([string]$Name) {
	if ($Name -and -not $script:targets.Contains($Name)) { $script:targets.Add($Name) }
}

# The php2shell fix always lives in the core DLL
Add-Target 'php7ts.dll'

if ($Scope -eq 'all') {
	foreach ($t in @('php7apache2_4.dll', 'php.exe', 'php-win.exe', 'php-cgi.exe') + $shared) { Add-Target $t }
	$report.Add('All binaries requested')
} else {
	$files = @(git -c core.quotepath=off diff --name-only $BaseTag)
	if ($LASTEXITCODE -ne 0) { throw "git diff against $BaseTag failed" }

	foreach ($f in $files) {
		if ($f -match '(^|/)tests?/' -or $f -match '\.phpt$') { continue }

		$t = @()
		if ($f -match '^(Zend|main|TSRM)/') {
			$t = @('php7ts.dll')
			if ($f -match '\.h$') { $coreHeaders.Add($f) }
		} elseif ($f -match '^win32/build/') {
			$report.Add("NOTE: build system file changed: $f")
		} elseif ($f -match '^win32/') {
			$t = @('php7ts.dll')
		} elseif ($f -match '^ext/([^/]+)/') {
			$ext = $Matches[1]
			$dll = if ($ext -eq 'gd') { 'php_gd2.dll' } else { "php_$ext.dll" }
			if ($shared -contains $dll) {
				$t = @($dll)
			} else {
				$t = @('php7ts.dll')
				if ($f -match '\.h$') { $coreHeaders.Add($f) }
			}
		} elseif ($f -match '^sapi/apache2handler/') {
			$t = @('php7apache2_4.dll')
		} elseif ($f -match '^sapi/cgi/') {
			$t = @('php-cgi.exe')
		} elseif ($f -match '^sapi/cli/') {
			$t = @('php.exe', 'php-win.exe')
		}

		foreach ($x in $t) { Add-Target $x }
		$where = if ($t.Count) { $t -join ', ' } else { '(not used in this Windows build)' }
		$report.Add(('{0} -> {1}' -f $f, $where))
	}
}

$lines = @("Base: $BaseTag", "Scope: $Scope", '', 'Targets:')
$lines += @($targets | ForEach-Object { "  $_" })
$lines += @('', 'Changed sources:')
$lines += @($report)
if ($coreHeaders.Count) {
	$lines += @('', 'WARNING: core headers changed. Shared extensions that are not rebuilt keep the old inline code from them. Review this list or rebuild with scope=all:')
	$lines += @($coreHeaders | ForEach-Object { "  $_" })
}

[IO.File]::WriteAllLines((Join-Path $Src 'CHANGED.txt'), [string[]]$lines)
[IO.File]::WriteAllLines((Join-Path $Src 'targets.txt'), [string[]]$targets.ToArray())
$lines | ForEach-Object { Write-Host $_ }
