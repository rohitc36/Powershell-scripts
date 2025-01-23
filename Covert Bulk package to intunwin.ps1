# Define the path to the IntuneWinAppUtil.exe
$intuneWinAppUtilPath = "C:\IntunePkg\IntuneWinAppUtil.exe"

# Check if the IntuneWinAppUtil.exe exists
if (-Not (Test-Path -Path $intuneWinAppUtilPath)) {
    Write-Error "The file IntuneWinAppUtil.exe was not found at the specified path: $intuneWinAppUtilPath"
    exit
}

# Define the source and output directories
$sourceDir = "C:\IntunePkg\Source"
$outputDir = "C:\IntunePkg\Output"

# Get all package directories in the source directory
$packages = Get-ChildItem -Path $sourceDir -Directory

foreach ($package in $packages) {
    $packagePath = $package.FullName
    $packageName = $package.Name
    $outputFile = Join-Path -Path $outputDir -ChildPath "$packageName.intunewin"

    # Check if the setup file exists
    $setupFile = Join-Path -Path $packagePath -ChildPath "Deploy-Application.exe"
    if (-Not (Test-Path -Path $setupFile)) {
        Write-Error "The setup file Deploy-Application.exe was not found in the package: $packageName"
        continue
    }

    # Run the IntuneWinAppUtil.exe to convert the package
    Start-Process -FilePath $intuneWinAppUtilPath -ArgumentList @(
        "-c", $packagePath,
        "-s", $setupFile,
        "-o", $outputDir
    ) -NoNewWindow -Wait

    # Check if the output file was created
    $generatedFile = Get-ChildItem -Path $outputDir -Filter "*.intunewin" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($generatedFile) {
        Rename-Item -Path $generatedFile.FullName -NewName "$packageName.intunewin"
        Write-Output "Converted $packageName to $outputFile"
    } else {
        Write-Error "Failed to create .intunewin file for $packageName"
    }
}
