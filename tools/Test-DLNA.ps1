#Requires -Version 5.1
<#
.SYNOPSIS
  Tests a DLNA/UPnP NAS from Windows using the same contract the iOS app uses.
  No installs needed - runs on built-in Windows PowerShell 5.1.

.EXAMPLE
  # 1. Discover step is manual on Windows (SSDP multicast is unreliable here).
  #    Get the description URL from your NAS, e.g.:
  #    Synology : http://<nas-ip>:50001/desc.xml
  #    MiniDLNA : http://<nas-ip>:8200/rootDesc.xml
  #    Jellyfin : http://<nas-ip>:8096/dlna/<id>/description
  .\tools\Test-DLNA.ps1 -LocationUrl "http://192.168.1.10:50001/desc.xml"

.EXAMPLE
  .\tools\Test-DLNA.ps1 -LocationUrl "http://192.168.1.10:8200/rootDesc.xml" -ObjectID "0"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$LocationUrl,
    [string]$ObjectID = "0"
)

$ErrorActionPreference = "Stop"

Write-Output "== 1/3 Fetch device description =="
Write-Output "GET $LocationUrl"
[xml]$desc = (Invoke-WebRequest -Uri $LocationUrl -UseBasicParsing -TimeoutSec 15).Content
$ns = @{ d = "urn:schemas-upnp-org:device-1-0" }
$friendly = Select-Xml -Xml $desc -Namespace $ns -XPath "//d:friendlyName" |
    Select-Object -First 1 -ExpandProperty Node | ForEach-Object { $_.InnerText }
Write-Output "Server: $friendly"

# Find ContentDirectory controlURL (same logic as DeviceDescriptionParser.swift)
$services = Select-Xml -Xml $desc -Namespace $ns -XPath "//d:service"
$controlRel = $null
foreach ($s in $services) {
    $type = $s.Node.serviceType
    if ($type -like "*ContentDirectory*") { $controlRel = $s.Node.controlURL; break }
}
if (-not $controlRel) { throw "No ContentDirectory service found in description XML." }
$base = New-Object System.Uri($LocationUrl)
$controlUrl = New-Object System.Uri($base, $controlRel).AbsoluteUri
Write-Output "Control URL: $controlUrl"

Write-Output ""
Write-Output "== 2/3 SOAP Browse (ObjectID=$ObjectID) =="
$soap = @"
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
      <ObjectID>$ObjectID</ObjectID>
      <BrowseFlag>BrowseDirectChildren</BrowseFlag>
      <Filter>*</Filter>
      <StartingIndex>0</StartingIndex>
      <RequestedCount>50</RequestedCount>
      <SortCriteria></SortCriteria>
    </u:Browse>
  </s:Body>
</s:Envelope>
"@
$resp = Invoke-WebRequest -Uri $controlUrl -Method Post -Body $soap `
    -ContentType "text/xml; charset=utf-8" `
    -Headers @{ SOAPACTION = '"urn:schemas-upnp-org:service:ContentDirectory:1#Browse"' } `
    -UseBasicParsing -TimeoutSec 30
[xml]$soapXml = $resp.Content
$resultNode = $soapXml.SelectSingleNode("//*[local-name()='Result']")
$didl = $resultNode.InnerText
Write-Output ("DIDL bytes: {0}" -f $didl.Length)

Write-Output ""
Write-Output "== 3/3 Tracks / folders =="
[xml]$d = "<root>$didl</root>"
$items = $d.SelectNodes("//*[local-name()='item']")
$containers = $d.SelectNodes("//*[local-name()='container']")
Write-Output ("Containers: {0}, audio items: {1}" -f $containers.Count, $items.Count)
foreach ($c in $containers | Select-Object -First 10) {
    $t = $c.SelectSingleNode("./*[local-name()='title']")
    Write-Output ("[folder] id={0} title={1}" -f $c.id, $t.InnerText)
}
foreach ($i in $items | Select-Object -First 20) {
    $t = $i.SelectSingleNode("./*[local-name()='title']")
    $res = $i.SelectSingleNode("./*[local-name()='res']")
    if ($res -ne $null) {
        Write-Output ("[track] {0} -> {1} (duration attr: {2})" -f $t.InnerText, $res.InnerText, $res.duration)
    }
}
Write-Output ""
Write-Output "OK - if tracks list here, the iOS DLNAService will play them (same SOAP contract)."
