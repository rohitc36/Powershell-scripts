# Define both file paths
$filePath1 = "$env:ProgramFiles(x86)\SAP BusinessObjects\Office AddIn\BiOfficeLauncher.exe"
$filePath2 = "$env:ProgramFiles\SAP BusinessObjects\Office AddIn\BiOfficeLauncher.exe"


# Define the expected version
$expectedVersion = "2.8.800.6347"

# Function to check file version
function Check-FileVersion($path, $expectedVersion) {
    if (Test-Path $path) {
        $version = (Get-Item $path).VersionInfo.FileVersion.Trim()
        Write-Host "Found version $version at $path"
        return [version]$version -ge $expectedVersion
    } else {
        Write-Host "Path not found: $path"
        return $false
    }
}

# Check either path
if ((Check-FileVersion $filePath1 $expectedVersion) -or (Check-FileVersion $filePath2 $expectedVersion)) {
    Write-Output "Detected"
    Exit 0
} else {
    Write-Output "Not Detected"
    Exit 1
}
