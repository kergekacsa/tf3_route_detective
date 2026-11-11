# Compiles the Teal modules that the tests load and runs every *_test.lua with Lua.
# Needs the Teal compiler and `lua55` on the PATH. Set $env:TL to use another compiler path.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$tl = if ($env:TL) { $env:TL } else { 'C:\Users\Kacsa\tools\teal\tl-0.24.8-windows-x86_64\tl.exe' }
$build = Join-Path $PSScriptRoot '.build'
$modules = 'route_state', 'route_lines', 'route_compare'

if (Test-Path $build) { Remove-Item -Recurse -Force $build }
New-Item -ItemType Directory -Force $build | Out-Null
Push-Location $root
try {
    foreach ($module in $modules) {
        & $tl gen -o (Join-Path $build "$module.lua") "../kacsa_person_route/content/person_route/$module.tl" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "tl gen failed for $module" }
    }
    $failed = 0
    foreach ($test in Get-ChildItem $PSScriptRoot -Filter '*_test.lua') {
        & lua55 $test.FullName
        if ($LASTEXITCODE -ne 0) { $failed++ }
    }
    if ($failed -gt 0) { Write-Host "$failed test file(s) failed"; exit 1 }
    Write-Host 'all test files passed'
}
finally {
    Pop-Location
}
