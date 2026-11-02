$ErrorActionPreference = 'Stop'
$compilerRoot = 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.43.34808'
$sdkRoot = 'C:\Program Files (x86)\Windows Kits\10'
$sdkVersion = '10.0.26100.0'
$env:INCLUDE = "$compilerRoot\include;$sdkRoot\Include\$sdkVersion\ucrt;$sdkRoot\Include\$sdkVersion\shared;$sdkRoot\Include\$sdkVersion\um"
$env:LIB = "$compilerRoot\lib\x64;$sdkRoot\Lib\$sdkVersion\ucrt\x64;$sdkRoot\Lib\$sdkVersion\um\x64"
$compiler = "$compilerRoot\bin\Hostx64\x64\cl.exe"
$buildDir = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Push-Location $buildDir
try {
    & $compiler /nologo /O2 /MT /EHsc /std:c++17 /utf-8 /LD ../library_backend.cpp /Fe:MMDRiseLibrary.dll
    if ($LASTEXITCODE -ne 0) { throw 'Library plugin compilation failed' }
    & $compiler /nologo /O2 /MT /EHsc /std:c++17 /utf-8 /DMMDRISE_LIBRARY_HOST ../library_backend.cpp /Fe:MMDRiseLibraryHost.exe
    if ($LASTEXITCODE -ne 0) { throw 'Library host compilation failed' }
} finally { Pop-Location }
