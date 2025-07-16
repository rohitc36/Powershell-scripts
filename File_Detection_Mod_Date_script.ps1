# Define both file paths
$filePath1 = "C:\Program Files (x86)\iManage\Work\iwAgent.exe"
$filePath2 = "C:\Program Files\iManage\Work\iwAgent.exe"

# Define the expected modified date
$expectedDate = Get-Date "2022-04-20"

# Function to check file modified date
function Check-FileModifiedDate($path, $expectedDate) {
    if (Test-Path $path) {
        $modifiedDate = (Get-Item $path).LastWriteTime.Date
        Write-Host "Found modified date $modifiedDate at $path"
        return $modifiedDate -ge $expectedDate.Date
    } else {
        Write-Host "Path not found: $path"
        return $false
    }
}

# Check either path
if ((Check-FileModifiedDate $filePath1 $expectedDate) -or (Check-FileModifiedDate $filePath2 $expectedDate)) {
    Write-Output "Detected"
    Exit 0
} else {
    Write-Output "Not Detected"
    Exit 1
}
