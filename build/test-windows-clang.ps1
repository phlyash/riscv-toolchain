param(
    [Parameter(Mandatory = $true)]
    [string] $Archive
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

function Require-File {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required packaged tool is missing: $Path"
    }
}

$archivePath = (Resolve-Path -LiteralPath $Archive).Path
$scratchParent = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$scratchRoot = Join-Path $scratchParent ("niiet-windows-smoke-" + [Guid]::NewGuid())
$utf8NoBom = [Text.UTF8Encoding]::new($false)

try {
    New-Item -ItemType Directory -Path $scratchRoot | Out-Null
    Expand-Archive -LiteralPath $archivePath -DestinationPath $scratchRoot

    $toolchainRoot = $scratchRoot
    $bin = Join-Path $toolchainRoot "bin"
    $sysroot = Join-Path $toolchainRoot "riscv32-unknown-elf"
    $clang = Join-Path $bin "clang.exe"
    $gcc = Join-Path $bin "riscv32-unknown-elf-gcc.exe"
    $gdb = Join-Path $bin "riscv32-unknown-elf-gdb.exe"
    $readelf = Join-Path $bin "riscv32-unknown-elf-readelf.exe"

    foreach ($tool in @($clang, $gcc, $gdb, $readelf)) {
        Require-File -Path $tool
    }
    if (-not (Test-Path -LiteralPath $sysroot -PathType Container)) {
        throw "Packaged GCC sysroot is missing: $sysroot"
    }

    Invoke-Checked -FilePath $clang -Arguments @("--version")
    Invoke-Checked -FilePath $gcc -Arguments @("--version")

    $commonArguments = @(
        "--target=riscv32-unknown-elf",
        "--gcc-toolchain=$toolchainRoot",
        "--sysroot=$sysroot",
        "-march=rv32imafc_zicsr_zifencei",
        "-mabi=ilp32f",
        "-Og",
        "-g3"
    )

    # This infinite loop reproduces the loop-deletion optimizer crash seen in
    # the former GNU-MinGW-hosted clang.exe. Do not weaken this to -O0 or add
    # an LLVM pass workaround: the native artifact itself must be healthy.
    $optimizerSource = Join-Path $scratchRoot "optimizer-smoke.c"
    $optimizerObject = Join-Path $scratchRoot "optimizer-smoke.o"
    [IO.File]::WriteAllText(
        $optimizerSource,
        "void spin(void) { for (;;) { __asm__ volatile(`"ebreak`"); } }`n",
        $utf8NoBom
    )
    Invoke-Checked -FilePath $clang -Arguments @(
        $commonArguments + @("-c", $optimizerSource, "-o", $optimizerObject)
    )
    Require-File -Path $optimizerObject

    # uint64_t division on RV32 requires a GCC libgcc helper. A successful
    # normal driver link proves Clang discovers the packaged GCC headers,
    # sysroot, startup files, libraries, and matching multilib directory.
    $runtimeSource = Join-Path $scratchRoot "gcc-runtime-smoke.c"
    $runtimeElf = Join-Path $scratchRoot "gcc-runtime-smoke.elf"
    $runtimeProgram = @'
#include <stdint.h>

volatile uint64_t dividend = UINT64_C(0xfedcba9876543210);
volatile uint64_t divisor = UINT64_C(1234567);

int main(void) {
    return (int)(dividend / divisor);
}
'@
    [IO.File]::WriteAllText($runtimeSource, $runtimeProgram, $utf8NoBom)
    Invoke-Checked -FilePath $clang -Arguments @(
        $commonArguments + @(
            "--rtlib=libgcc",
            $runtimeSource,
            "-o",
            $runtimeElf
        )
    )
    Require-File -Path $runtimeElf

    $elfHeader = (& $readelf -h $runtimeElf 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "$readelf failed with exit code $LASTEXITCODE"
    }
    Write-Host $elfHeader
    if ($elfHeader -notmatch "Machine:\s+RISC-V") {
        throw "Clang link output is not a RISC-V ELF file"
    }
    if ($elfHeader -notmatch "Class:\s+ELF32") {
        throw "Clang link output is not ELF32"
    }

    $gdbConfiguration = (& $gdb --configuration 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "$gdb --configuration failed with exit code $LASTEXITCODE"
    }
    Write-Host $gdbConfiguration
    foreach ($feature in @("--enable-tui", "--with-curses", "--with-expat")) {
        if (-not $gdbConfiguration.Contains($feature)) {
            throw "Packaged GDB configuration is missing $feature"
        }
    }
    if ($gdbConfiguration.Contains("--without-expat")) {
        throw "Packaged GDB was built without expat"
    }

    $invalidXml = Join-Path $scratchRoot "invalid-target.xml"
    [IO.File]::WriteAllText(
        $invalidXml,
        '<?xml version="1.0"?><target>',
        $utf8NoBom
    )
    $xmlProbe = (& $gdb -nx -batch -ex "set tdesc filename $invalidXml" 2>&1 | Out-String)
    Write-Host $xmlProbe
    if ($xmlProbe.Contains("XML support was disabled at compile time")) {
        throw "Packaged GDB XML parser is disabled"
    }
    if ($xmlProbe -notmatch "while parsing target description|Could not load XML target description") {
        throw "Packaged GDB XML probe did not reach the expat parser"
    }

    Write-Host "PASS: packaged Windows Clang optimizer, GCC runtime, and GDB XML smoke checks"
}
finally {
    if (Test-Path -LiteralPath $scratchRoot) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force
    }
}
