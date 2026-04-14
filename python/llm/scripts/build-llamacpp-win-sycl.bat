@echo off
:: ============================================================
:: build-llamacpp-win-sycl.bat
:: Builds llama.cpp with Intel SYCL backend on Windows locally.
:: Adds Gemma 4 (gemma4 architecture) support missing in ipex-llm 2.2.0.
::
:: Prerequisites:
::   1. Intel oneAPI Base Toolkit 2024.2+ installed
::      https://www.intel.com/content/www/us/en/developer/tools/oneapi/base-toolkit-download.html
::   2. CMake 3.21+ installed (https://cmake.org/download/)
::   3. Ninja build tool OR Visual Studio 2019/2022 with C++ workload
::   4. Git
::
:: Usage:
::   build-llamacpp-win-sycl.bat [llama_cpp_ref] [output_dir]
::
::   llama_cpp_ref  - branch/tag/commit of ggml-org/llama.cpp (default: master)
::   output_dir     - where to put the ZIP release (default: current dir)
::
:: Example:
::   build-llamacpp-win-sycl.bat master C:\my_release
:: ============================================================

setlocal EnableDelayedExpansion

set LLAMA_CPP_REF=%~1
if "%LLAMA_CPP_REF%"=="" set LLAMA_CPP_REF=master

set OUTPUT_DIR=%~2
if "%OUTPUT_DIR%"=="" set OUTPUT_DIR=%CD%

set WORK_DIR=%TEMP%\llama_cpp_gemma4_build
set SOURCE_DIR=%WORK_DIR%\llama_cpp_src
set BUILD_DIR=%WORK_DIR%\build
set RELEASE_DIR=%WORK_DIR%\release-win

echo.
echo ============================================================
echo  Build llama.cpp with Gemma 4 support (Intel SYCL / Windows)
echo ============================================================
echo  llama.cpp ref : %LLAMA_CPP_REF%
echo  Work dir      : %WORK_DIR%
echo  Output dir    : %OUTPUT_DIR%
echo.

:: ─── Check prerequisites ──────────────────────────────────
echo [1/7] Checking prerequisites...

where git >nul 2>&1
if errorlevel 1 (
    echo ERROR: git not found. Install from https://git-scm.com/
    exit /b 1
)

where cmake >nul 2>&1
if errorlevel 1 (
    echo ERROR: cmake not found. Install from https://cmake.org/download/
    echo        or: winget install Kitware.CMake
    exit /b 1
)

:: Check oneAPI - setvars.bat must exist
set SETVARS=""
if exist "C:\Program Files (x86)\Intel\oneAPI\setvars.bat" (
    set SETVARS="C:\Program Files (x86)\Intel\oneAPI\setvars.bat"
) else if exist "C:\Program Files\Intel\oneAPI\setvars.bat" (
    set SETVARS="C:\Program Files\Intel\oneAPI\setvars.bat"
) else (
    echo ERROR: Intel oneAPI not found.
    echo        Download from:
    echo        https://www.intel.com/content/www/us/en/developer/tools/oneapi/base-toolkit-download.html
    echo.
    echo        Install at minimum these components:
    echo          - Intel DPC++ Compiler
    echo          - Intel oneAPI Math Kernel Library ^(MKL^)
    echo          - Intel oneAPI Threading Building Blocks ^(TBB^)
    exit /b 1
)
echo   OK: oneAPI found at %SETVARS%

:: ─── Setup oneAPI environment ─────────────────────────────
echo [2/7] Activating Intel oneAPI environment...
call %SETVARS% intel64
if errorlevel 1 (
    echo ERROR: Failed to activate oneAPI environment.
    exit /b 1
)

:: Verify icx compiler is available
where icx >nul 2>&1
if errorlevel 1 (
    echo ERROR: icx compiler not found after oneAPI activation.
    exit /b 1
)
echo   OK: Intel DPC++ compiler ready
icx --version 2>&1 | findstr /i "version"

:: ─── Clone llama.cpp ──────────────────────────────────────
echo [3/7] Cloning llama.cpp @ %LLAMA_CPP_REF%...
if exist "%SOURCE_DIR%" (
    echo   Removing existing source dir...
    rmdir /s /q "%SOURCE_DIR%"
)
git clone --depth=1 --branch "%LLAMA_CPP_REF%" ^
    https://github.com/ggml-org/llama.cpp.git "%SOURCE_DIR%"
if errorlevel 1 (
    echo   Branch not found, trying as commit/tag...
    git clone --depth=1 https://github.com/ggml-org/llama.cpp.git "%SOURCE_DIR%"
    cd /d "%SOURCE_DIR%"
    git checkout "%LLAMA_CPP_REF%"
    if errorlevel 1 (
        echo ERROR: Could not checkout ref '%LLAMA_CPP_REF%'
        exit /b 1
    )
    cd /d "%~dp0"
)

:: Get the commit SHA for naming
cd /d "%SOURCE_DIR%"
for /f "tokens=*" %%i in ('git rev-parse --short HEAD') do set LLAMA_COMMIT=%%i
cd /d "%~dp0"
echo   Building from commit: %LLAMA_COMMIT%

:: Verify gemma4 support
findstr /r /s "gemma4" "%SOURCE_DIR%\src\*.cpp" >nul 2>&1
if errorlevel 1 (
    echo.
    echo WARNING: gemma4 architecture NOT found in this llama.cpp version.
    echo          Try using a newer commit/branch, e.g.:
    echo          build-llamacpp-win-sycl.bat master
    echo.
    echo          Continuing anyway - the build will succeed but Gemma 4 models
    echo          will not be supported in the output binaries.
    echo.
    pause
)

:: ─── Configure CMake ──────────────────────────────────────
echo [4/7] Configuring CMake (SYCL backend)...
if exist "%BUILD_DIR%" rmdir /s /q "%BUILD_DIR%"

cmake -B "%BUILD_DIR%" -S "%SOURCE_DIR%" ^
    -G "Ninja" ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DGGML_SYCL=ON ^
    -DCMAKE_C_COMPILER=icx ^
    -DCMAKE_CXX_COMPILER=icx ^
    -DGGML_SYCL_F16=ON ^
    -DBUILD_SHARED_LIBS=ON ^
    -DLLAMA_BUILD_TESTS=OFF ^
    -DLLAMA_BUILD_EXAMPLES=ON
if errorlevel 1 (
    echo ERROR: CMake configuration failed.
    echo        Check that Ninja is installed: winget install Ninja-build.Ninja
    exit /b 1
)

:: ─── Build ────────────────────────────────────────────────
echo [5/7] Building (this takes 10-20 minutes)...
cmake --build "%BUILD_DIR%" --config Release
if errorlevel 1 (
    echo ERROR: Build failed.
    exit /b 1
)
echo   Build complete.

:: ─── Package ──────────────────────────────────────────────
echo [6/7] Packaging release...
if exist "%RELEASE_DIR%" rmdir /s /q "%RELEASE_DIR%"
mkdir "%RELEASE_DIR%"

:: Copy EXEs (exclude test binaries)
for %%f in ("%BUILD_DIR%\bin\*.exe") do (
    echo %%~nxf | findstr /i "test" >nul || (
        copy "%%f" "%RELEASE_DIR%\" >nul
        echo   + %%~nxf
    )
)

:: Copy DLLs from build
for %%f in ("%BUILD_DIR%\bin\*.dll") do (
    copy "%%f" "%RELEASE_DIR%\" >nul
    echo   + %%~nxf
)
for %%f in ("%BUILD_DIR%\*.dll") do (
    copy "%%f" "%RELEASE_DIR%\" >nul
    echo   + %%~nxf
)

:: Copy required Intel oneAPI runtime DLLs
echo   Copying Intel runtime DLLs...

:: SYCL runtime
for %%d in (
    "C:\Program Files (x86)\Intel\oneAPI\compiler\latest\bin"
    "C:\Program Files (x86)\Intel\oneAPI\compiler\latest\windows\bin"
) do (
    if exist "%%~d" (
        for %%f in ("%%~d\sycl?.dll" "%%~d\sycl??.dll" "%%~d\OpenCL.dll" "%%~d\libiomp5md.dll" "%%~d\libmmd.dll" "%%~d\svml_dispmd.dll") do (
            if exist "%%f" if not exist "%RELEASE_DIR%\%%~nxf" (
                copy "%%f" "%RELEASE_DIR%\" >nul 2>&1
                echo   + [oneAPI] %%~nxf
            )
        )
    )
)

:: Unified Runtime (for GPU access)
for %%d in (
    "C:\Program Files (x86)\Intel\oneAPI\compiler\latest\bin"
    "C:\Windows\System32"
) do (
    if exist "%%~d" (
        for %%f in ("%%~d\ur_loader.dll" "%%~d\ur_adapter_level_zero.dll" "%%~d\ur_adapter_opencl.dll" "%%~d\ur_win_proxy_loader.dll") do (
            if exist "%%f" if not exist "%RELEASE_DIR%\%%~nxf" (
                copy "%%f" "%RELEASE_DIR%\" >nul 2>&1
                echo   + [UR] %%~nxf
            )
        )
    )
)

:: MKL
for %%d in (
    "C:\Program Files (x86)\Intel\oneAPI\mkl\latest\bin"
    "C:\Program Files (x86)\Intel\oneAPI\mkl\latest\bin\intel64"
) do (
    if exist "%%~d" (
        for %%f in ("%%~d\mkl_core.*.dll" "%%~d\mkl_sycl_blas.*.dll" "%%~d\mkl_tbb_thread.*.dll" "%%~d\dnnl.dll") do (
            if exist "%%f" if not exist "%RELEASE_DIR%\%%~nxf" (
                copy "%%f" "%RELEASE_DIR%\" >nul 2>&1
                echo   + [MKL] %%~nxf
            )
        )
    )
)

:: TBB
for %%d in (
    "C:\Program Files (x86)\Intel\oneAPI\tbb\latest\bin"
    "C:\Program Files (x86)\Intel\oneAPI\tbb\latest\bin\intel64\vc14"
) do (
    if exist "%%~d" (
        for %%f in ("%%~d\tbb12.dll" "%%~d\tbbmalloc.dll") do (
            if exist "%%f" if not exist "%RELEASE_DIR%\%%~nxf" (
                copy "%%f" "%RELEASE_DIR%\" >nul 2>&1
                echo   + [TBB] %%~nxf
            )
        )
    )
)

:: Write README
(
echo llama.cpp for Intel GPU ^(Windows^) — Gemma 4 support
echo ======================================================
echo Built from: https://github.com/ggml-org/llama.cpp @ %LLAMA_COMMIT%
echo Intel SYCL backend: enabled
echo Gemma 4 ^(gemma4 architecture^): supported
echo.
echo QUICK START
echo -----------
echo 1. Set environment:
echo    set SYCL_CACHE_PERSISTENT=1
echo.
echo 2. Run Gemma 4 ^(text-only GGUF^):
echo    llama-cli.exe -m gemma-4-E4B-it-Q4_K_M.gguf -n 256 --prompt "What is AI?" -ngl 99
echo.
echo 3. Optional performance boost:
echo    set SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS=1
echo.
echo NOTES
echo -----
echo - Requires Intel GPU driver ^>= 31.0.101.5522
echo - Update from: https://www.intel.com/content/www/us/en/download/785597
echo - For multi-GPU: set ONEAPI_DEVICE_SELECTOR=level_zero:0
) > "%RELEASE_DIR%\README.txt"

:: ─── Create ZIP ───────────────────────────────────────────
echo [7/7] Creating ZIP archive...
set ZIP_NAME=llama-cpp-gemma4-win-%LLAMA_COMMIT%.zip

if not exist "%OUTPUT_DIR%" mkdir "%OUTPUT_DIR%"

powershell -NoProfile -Command ^
    "Compress-Archive -Path '%RELEASE_DIR%\*' -DestinationPath '%OUTPUT_DIR%\%ZIP_NAME%' -Force"
if errorlevel 1 (
    echo ERROR: Failed to create ZIP.
    exit /b 1
)

echo.
echo ============================================================
echo  BUILD COMPLETE
echo ============================================================
echo  Release: %OUTPUT_DIR%\%ZIP_NAME%
echo.
echo  To use:
echo    1. Extract %ZIP_NAME% to a folder
echo    2. Open Command Prompt, cd to that folder
echo    3. set SYCL_CACHE_PERSISTENT=1
echo    4. llama-cli.exe -m YOUR_MODEL.gguf -n 256 --prompt "Hello" -ngl 99
echo ============================================================

endlocal
