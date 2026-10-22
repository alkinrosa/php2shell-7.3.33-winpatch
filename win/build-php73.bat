@echo off
setlocal enabledelayedexpansion

set VARIANT=%~1
set MODE=%~2
set PHPVER=7.3.33
set ROOT=C:\php-build
set REPO=%GITHUB_WORKSPACE%
set SYS=%SystemRoot%\System32

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

if /i "%MODE%"=="modphp" (
	set CONF_MODE=--enable-apache2-4handler
	set OUT=%ROOT%\src\x64\Release_TS
) else if /i "%MODE%"=="fcgid" (
	set CONF_MODE=--disable-zts
	set OUT=%ROOT%\src\x64\Release
) else (
	echo Unknown mode "%MODE%"
	exit /b 1
)

mkdir "%ROOT%" 2>nul
cd /d "%ROOT%" || exit /b 1

rem --- Sources ---
if /i "%VARIANT%"=="remicollet" (
	git clone --depth 1 --branch PHP-7.3-security-backports https://github.com/remicollet/php-src-security.git src || exit /b 1
) else (
	"%SYS%\curl.exe" -sSfL -o php.tar.gz https://www.php.net/distributions/php-%PHPVER%.tar.gz || exit /b 1
	mkdir src
	"%SYS%\tar.exe" -xzf php.tar.gz -C src --strip-components=1 || exit /b 1
)

cd /d "%ROOT%\src" || exit /b 1

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

rem --- Apache 2.4 headers and libs (mod_php only) ---
if /i "%MODE%"=="modphp" (
	xcopy /e /i /y /q "%REPO%\win\apache24\include" "%ROOT%\deps\include\apache2_4" >nul || exit /b 1
	mkdir "%ROOT%\deps\lib\apache2_4" 2>nul
	copy /y "%REPO%\win\apache24\lib\*.lib" "%ROOT%\deps\lib\apache2_4\" >nul || exit /b 1
)

rem --- Build ---
call buildconf.bat || exit /b 1
call configure.bat --enable-snapshot-build --enable-com-dotnet=shared --without-analyzer %CONF_MODE% || exit /b 1
nmake || exit /b 1
nmake snap || exit /b 1

rem --- Smoke tests ---
"%OUT%\php.exe" -v || exit /b 1
"%OUT%\php.exe" -m | findstr /i /x session || exit /b 1
"%OUT%\php.exe" -n -r "class A{public $x=1;} echo get_class(unserialize(serialize(new A)));" | findstr /x A || exit /b 1
if /i "%MODE%"=="modphp" (
	if not exist "%OUT%\php7apache2_4.dll" (echo php7apache2_4.dll was not built & exit /b 1)
) else (
	if not exist "%OUT%\php-cgi.exe" (echo php-cgi.exe was not built & exit /b 1)
)

rem --- Tests (non-fatal) ---
nmake test TESTS="ext\session\tests ext\standard\tests\serialize" || echo Some tests failed, check the log

echo ok> "%ROOT%\BUILD_OK"
exit /b 0
