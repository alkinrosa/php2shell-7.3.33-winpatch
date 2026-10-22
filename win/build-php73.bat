@echo off
setlocal enabledelayedexpansion

set VARIANT=%~1
set SCOPE=%~2
if "%SCOPE%"=="" set SCOPE=changed
set PHPVER=7.3.33
set BASETAG=php-%PHPVER%
set ROOT=C:\php-build
set REPO=%GITHUB_WORKSPACE%
set SYS=%SystemRoot%\System32
set OUT=%ROOT%\src\x64\Release_TS
set DIST=%ROOT%\dist

if /i "%VARIANT%"=="remicollet" (
	set PATCH=%REPO%\patches\php-7.3-enhanced-remicollet.patch
) else if /i "%VARIANT%"=="minimal" (
	set PATCH=%REPO%\patches\php-7.3-minimal.patch
) else if /i "%VARIANT%"=="enhanced" (
	set PATCH=%REPO%\patches\php-7.3-enhanced-universal.patch
) else (
	echo Unknown variant "%VARIANT%"
	exit /b 1
)

if /i not "%SCOPE%"=="changed" if /i not "%SCOPE%"=="all" (
	echo Unknown scope "%SCOPE%"
	exit /b 1
)

mkdir "%ROOT%" 2>nul
cd /d "%ROOT%" || exit /b 1

rem --- Sources, with the official %BASETAG% tag available for comparison ---
if /i "%VARIANT%"=="remicollet" (
	git clone --depth 1 --branch PHP-7.3-security-backports https://github.com/remicollet/php-src-security.git src || exit /b 1
	cd /d "%ROOT%\src" || exit /b 1
	git fetch --depth 1 --force https://github.com/php/php-src.git refs/tags/%BASETAG%:refs/tags/%BASETAG% || exit /b 1
) else (
	"%SYS%\curl.exe" -sSfL -o php.tar.gz https://www.php.net/distributions/php-%PHPVER%.tar.gz || exit /b 1
	mkdir src
	"%SYS%\tar.exe" -xzf php.tar.gz -C src --strip-components=1 || exit /b 1
	cd /d "%ROOT%\src" || exit /b 1
	git init -q || exit /b 1
	git add -A || exit /b 1
	git -c user.name=ci -c user.email=ci@localhost commit -q -m base || exit /b 1
	git tag %BASETAG% || exit /b 1
)

rem --- Patch ---
git apply --verbose "%PATCH%" || exit /b 1

rem --- Remi tree must already contain the multipart body parts limit ---
if /i "%VARIANT%"=="remicollet" (
	findstr /c:"max_multipart_body_parts" main\main.c >nul || (echo Remi tree lacks max_multipart_body_parts & exit /b 1)
)

rem --- Dependencies were downloaded by the workflow to ..\deps ---
if not exist "%ROOT%\deps\include\openssl\ssl.h" (
	echo Dependencies not found in %ROOT%\deps
	exit /b 1
)
if not exist "%ROOT%\deps\include\apache2_4\httpd.h" (echo httpd.h not found in deps\include\apache2_4 & exit /b 1)
if not exist "%ROOT%\deps\lib\apache2_4\libhttpd.lib" (echo libhttpd.lib not found in deps\lib\apache2_4 & exit /b 1)

rem --- Configure exactly like the official snapshot build ---
call buildconf.bat || exit /b 1
call configure.bat --enable-snapshot-build --enable-com-dotnet=shared --without-analyzer --enable-apache2-4handler || exit /b 1

rem --- Decide what to build ---
pwsh -NoProfile -ExecutionPolicy Bypass -File "%REPO%\win\changed-targets.ps1" -Src "%ROOT%\src" -BaseTag %BASETAG% -Scope %SCOPE% || exit /b 1

rem --- CLI and CGI: needed for the tests, and they build php7ts.dll (it has no nmake target of its own) ---
echo === Building php.exe and php-cgi.exe (with php7ts.dll) ===
nmake php.exe || exit /b 1
nmake php-cgi.exe || exit /b 1
if not exist "%OUT%\php7ts.dll" (echo php7ts.dll was not built & exit /b 1)

rem --- Build the other selected targets ---
for /f "usebackq delims=" %%T in ("%ROOT%\src\targets.txt") do (
	if /i not "%%T"=="php7ts.dll" (
		echo === Building %%T ===
		nmake %%T || exit /b 1
	)
)

rem --- Smoke tests ---
"%OUT%\php.exe" -v || exit /b 1
"%OUT%\php.exe" -n -r "exit(extension_loaded('session') ? 0 : 1);" || (echo session extension is missing & exit /b 1)
"%OUT%\php.exe" -n -r "class A{public $x=1;} exit(get_class(unserialize(serialize(new A))) === 'A' ? 0 : 1);" || (echo unserialize smoke test failed & exit /b 1)
echo Smoke tests passed

rem --- Collect only the selected binaries, laid out like the PHP folder ---
rmdir /s /q "%DIST%" 2>nul
mkdir "%DIST%\ext" || exit /b 1
for /f "usebackq delims=" %%T in ("%ROOT%\src\targets.txt") do (
	set NAME=%%T
	if /i "!NAME:~0,4!"=="php_" (
		copy /y "%OUT%\%%T" "%DIST%\ext\" >nul || exit /b 1
	) else (
		copy /y "%OUT%\%%T" "%DIST%\" >nul || exit /b 1
	)
)
copy /y "%ROOT%\src\CHANGED.txt" "%DIST%\" >nul || exit /b 1
if exist "%ROOT%\src\HEADERS.diff" copy /y "%ROOT%\src\HEADERS.diff" "%DIST%\" >nul

rem --- Tests (non-fatal) ---
set NO_INTERACTION=1
set TEST_PHP_EXECUTABLE=%OUT%\php.exe
set TEST_PHP_CGI_EXECUTABLE=%OUT%\php-cgi.exe
"%OUT%\php.exe" -n run-tests.php -q -p "%OUT%\php.exe" ext\session\tests ext\standard\tests\serialize || echo Some tests failed, check the log

echo ok> "%ROOT%\BUILD_OK"
exit /b 0
