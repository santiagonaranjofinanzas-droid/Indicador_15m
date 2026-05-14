Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

param(
    [string]$Host = "127.0.0.1",
    [int]$Port = 8888,
    [ValidateSet("DEBUG", "INFO", "WARNING", "ERROR")]
    [string]$LogLevel = "INFO"
)

$workspaceRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$pythonExe = Join-Path $workspaceRoot ".venv\Scripts\python.exe"
$serverScript = Join-Path $PSScriptRoot "quant_server.py"

if (-not (Test-Path $pythonExe)) {
    throw "Python executable not found: $pythonExe"
}
if (-not (Test-Path $serverScript)) {
    throw "Server script not found: $serverScript"
}

$env:Black_Knight_Aut_System_HOST = $Host
$env:Black_Knight_Aut_System_PORT = [string]$Port
$env:Black_Knight_Aut_System_LOG_LEVEL = $LogLevel

Write-Host "Starting Black_Knight_Aut_System demo server on $Host`:$Port (log=$LogLevel)"
& $pythonExe $serverScript
