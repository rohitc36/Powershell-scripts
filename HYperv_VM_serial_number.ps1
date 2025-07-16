[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$HypervHost ="INPF4EFP4X"
$GuestName = ""

if ($GuestName -ne "") {
  Get-WmiObject -ComputerName $HypervHost `
    -Namespace root\virtualization\v2 -class Msvm_VirtualSystemSettingData | 
      ? {$_.elementName -eq $GuestName} |
        Select -ExpandProperty BIOSSerialNumber
}
else {
  Get-WmiObject -ComputerName $HypervHost `
    -Namespace root\virtualization\v2 -class Msvm_VirtualSystemSettingData | 
    ? {$_.BIOSSerialNumber -ne $null} |
      Select elementname, BIOSSerialNumber |
        Sort-Object elementName
        }
