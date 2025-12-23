@echo off
REM Build nijilive-unity.dll using LDC 1.41 as per doc/plan.md

setlocal
set DFLAGS=-link-defaultlib-shared=false --dllimport=none

set LDC_BIN=C:\opt\ldc-1.41\bin
set DUB=%LDC_BIN%\dub.exe
set PATH=%LDC_BIN%;%PATH%

echo === Rebuilding dependencies with static runtime ===
pushd %LOCALAPPDATA%\dub\packages\mir-core\1.7.3\mir-core
%DUB% build -q --compiler=ldc2 --force
popd

pushd %LOCALAPPDATA%\dub\packages\mir-algorithm\3.22.4\mir-algorithm
%DUB% build -q --compiler=ldc2 --force
popd

pushd %LOCALAPPDATA%\dub\packages\fghj\1.0.2\fghj
%DUB% build -q --compiler=ldc2 --force
popd

pushd %LOCALAPPDATA%\dub\packages\inmath\1.0.6\inmath
%DUB% build -q --compiler=ldc2 --force
popd

echo === Building nijilive-unity.dll ===
%DUB% build -q --config unity-dll

endlocal
echo Done.
