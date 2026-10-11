#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads, patches, and installs Apple Music for Windows 10 (21H2 /
    build 19044 and newer), end to end, with one command:

        irm https://raw.githubusercontent.com/b3s3da/AppleMusicForW10/main/install.ps1 | iex

.DESCRIPTION
    This script never ships, stores, or redistributes any Apple binary.
    Instead it fetches the current AppleMusic.msixbundle directly from
    Microsoft's own package delivery servers (fe3.delivery.mp.microsoft.com),
    using the same public, documented protocol winget and the Microsoft
    Store app itself use (MS-WUSP: GetCookie -> SyncUpdates ->
    GetExtendedUpdateInfo2). This keeps the repository itself free of any
    third-party copyrighted content.

    It then patches the manifest and AMP.Utils.dll in a temp folder (see
    docs/root-cause-analysis.md for why), installs into
    %LOCALAPPDATA%\Programs\AppleMusic, and registers the package.

    Re-running this script to pick up an Apple Music update does NOT wipe
    your Apple ID sign-in or local library cache: the package family name
    stays the same across runs (AppleInc.AppleMusicW10), so the install is
    a normal in-place Add-AppxPackage -Register upgrade, which Windows
    treats as an update of the same app rather than a reinstall. The
    destructive Remove-AppxPackage step only ever runs once, the first
    time this script sees the *original* Apple package
    (AppleInc.AppleMusicWin) registered, to get rid of its broken
    StateRepository entry (see docs/root-cause-analysis.md).

.PARAMETER Dest
    Installation directory. Default: %LOCALAPPDATA%\Programs\AppleMusic.

.PARAMETER Launch
    Launch Apple Music once installation finishes.

.PARAMETER KeepDownload
    Keep the downloaded/patched files in a visible temp folder instead of
    cleaning them up (useful for debugging).
#>
[CmdletBinding()]
param(
    [string]$Dest = (Join-Path $env:LOCALAPPDATA 'Programs\AppleMusic'),
    [switch]$Launch,
    [switch]$KeepDownload
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Microsoft Store product ID for the official "Apple Music" Windows app.
$StoreProductId = '9PFHDD62MXS1'

# Package identity names. See docs/root-cause-analysis.md for why a
# same-length rename is required (StateRepository / AMP.Utils.dll checks).
$OrigPackageName = 'AppleInc.AppleMusicWin'
$NewPackageName = 'AppleInc.AppleMusicW10'
$TargetMinVersion = '10.0.19044.0'

$WuServiceUrl = 'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx'
$WuSecuredUrl = "$WuServiceUrl/secured"

$SignatureFilesToRemove = @(
    'AppxSignature.p7x'
    'AppxBlockMap.xml'
    '[Content_Types].xml'
    'AppxMetadata\CodeIntegrity.cat'
)

# ---------------------------------------------------------------------------
# Step 0: fetch the current package metadata + direct CDN download URL,
# straight from Microsoft, no third-party site involved.
# ---------------------------------------------------------------------------

function Get-WuCategoryId {
    param([string]$ProductId)
    $url = "https://storeedgefd.dsx.mp.microsoft.com/v9.0/products/$ProductId`?market=US&locale=en-us&deviceFamily=Windows.Desktop"
    $resp = Invoke-RestMethod -Uri $url -Method Get
    $sku = $resp.Payload.Skus | Where-Object { $_.FulfillmentData } | Select-Object -First 1
    if (-not $sku) { throw "No SKU with FulfillmentData found for Microsoft Store product $ProductId" }
    $fd = $sku.FulfillmentData | ConvertFrom-Json
    return $fd.WuCategoryId
}

function New-SoapTimestamps {
    [pscustomobject]@{
        Created   = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        Expires   = [DateTime]::UtcNow.AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        MessageId = [guid]::NewGuid().ToString()
    }
}

# Boilerplate shared by every SOAP request: WS-Security timestamp plus an
# (empty/anonymous) WindowsUpdateTicketsToken. Windows Update's FE3
# endpoint requires this block to be present to accept the message at all,
# even for anonymous/unauthenticated requests like this one.
function Get-SecurityHeaderXml {
    param([pscustomobject]$Timestamps)
    @"
<o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
<Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
<Created>$($Timestamps.Created)</Created><Expires>$($Timestamps.Expires)</Expires>
</Timestamp>
<WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization">
<TicketType Name="MSA" Version="1.0" Policy="MBI_SSL"></TicketType>
</WindowsUpdateTicketsToken>
</o:Security>
"@
}

function Get-WuCookie {
    $ts = New-SoapTimestamps
    $security = Get-SecurityHeaderXml -Timestamps $ts
    $body = @"
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
<s:Header>
<a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetCookie</a:Action>
<a:MessageID>urn:uuid:$($ts.MessageId)</a:MessageID>
<a:To s:mustUnderstand="1">$WuServiceUrl</a:To>
$security
</s:Header>
<s:Body>
<GetCookie xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
<oldCookie></oldCookie>
<lastChange>2015-10-21T17:01:07.1472913Z</lastChange>
<currentTime>$($ts.Created)</currentTime>
<protocolVersion>1.40</protocolVersion>
</GetCookie>
</s:Body>
</s:Envelope>
"@
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $WuServiceUrl -Method Post -Body $body -ContentType 'application/soap+xml; charset=utf-8'
    [xml]$xml = $resp.Content
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('wu', 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService')
    $result = $xml.SelectSingleNode('//wu:GetCookieResult', $ns)
    [pscustomobject]@{ EncryptedData = $result.EncryptedData; Expiration = $result.Expiration }
}

# A generic device-attributes string accepted by the FE3 endpoint for
# anonymous metadata queries (matches what Windows' own WU client sends).
$script:DeviceAttributes = 'BranchReadinessLevel=CB;CurrentBranch=rs_prerelease;OEMModel=Virtual Machine;FlightRing=Retail;AttrDataVer=21;SystemManufacturer=Microsoft Corporation;InstallLanguage=en-US;OSUILocale=en-US;InstallationType=Client;FlightingBranchName=external;FirmwareVersion=Hyper-V UEFI Release v2.5;SystemProductName=Virtual Machine;OSSkuId=48;FlightContent=Branch;App=WU;OEMName_Uncleaned=Microsoft Corporation;AppVer=10.0.22621.900;OSArchitecture=AMD64;SystemSKU=None;UpdateManagementGroup=2;IsFlightingEnabled=1;IsDeviceRetailDemo=0;TelemetryLevel=3;OSVersion=10.0.22621.900;DeviceFamily=Windows.Desktop;'

function Get-SyncUpdatesXml {
    param([string]$CategoryId, [pscustomobject]$Cookie)
    $ts = New-SoapTimestamps
    $security = Get-SecurityHeaderXml -Timestamps $ts
    $body = @"
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
<s:Header>
<a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/SyncUpdates</a:Action>
<a:MessageID>urn:uuid:$($ts.MessageId)</a:MessageID>
<a:To s:mustUnderstand="1">$WuServiceUrl</a:To>
$security
</s:Header>
<s:Body>
<SyncUpdates xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
<cookie><Expiration>$($Cookie.Expiration)</Expiration><EncryptedData>$($Cookie.EncryptedData)</EncryptedData></cookie>
<parameters>
<ExpressQuery>false</ExpressQuery>
<InstalledNonLeafUpdateIDs><int>1</int><int>2</int><int>3</int><int>11</int><int>19</int><int>544</int><int>549</int><int>2359974</int><int>2359977</int><int>5169044</int><int>8788830</int><int>23110993</int></InstalledNonLeafUpdateIDs>
<OtherCachedUpdateIDs></OtherCachedUpdateIDs>
<SkipSoftwareSync>false</SkipSoftwareSync>
<NeedTwoGroupOutOfScopeUpdates>true</NeedTwoGroupOutOfScopeUpdates>
<FilterAppCategoryIds><CategoryIdentifier><Id>$CategoryId</Id></CategoryIdentifier></FilterAppCategoryIds>
<TreatAppCategoryIdsAsInstalled>true</TreatAppCategoryIdsAsInstalled>
<AlsoPerformRegularSync>false</AlsoPerformRegularSync>
<ComputerSpec></ComputerSpec>
<ExtendedUpdateInfoParameters>
<XmlUpdateFragmentTypes><XmlUpdateFragmentType>Extended</XmlUpdateFragmentType></XmlUpdateFragmentTypes>
<Locales><string>en-US</string><string>en</string></Locales>
</ExtendedUpdateInfoParameters>
<ClientPreferredLanguages><string>en-US</string></ClientPreferredLanguages>
<ProductsParameters>
<SyncCurrentVersionOnly>false</SyncCurrentVersionOnly>
<DeviceAttributes>$($script:DeviceAttributes)</DeviceAttributes>
<CallerAttributes>Interactive=1;IsSeeker=0;</CallerAttributes>
<Products></Products>
</ProductsParameters>
</parameters>
</SyncUpdates>
</s:Body>
</s:Envelope>
"@
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $WuServiceUrl -Method Post -Body $body -ContentType 'application/soap+xml; charset=utf-8'
    # The <Xml> fragments inside the response are HTML-entity-escaped.
    $decoded = [System.Web.HttpUtility]::HtmlDecode($resp.Content)
    [xml]$xml = $decoded
    return $xml
}

function Get-FileUrlsXml {
    param([string]$UpdateId, [string]$Revision)
    $ts = New-SoapTimestamps
    $security = Get-SecurityHeaderXml -Timestamps $ts
    $body = @"
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
<s:Header>
<a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetExtendedUpdateInfo2</a:Action>
<a:MessageID>urn:uuid:$($ts.MessageId)</a:MessageID>
<a:To s:mustUnderstand="1">$WuSecuredUrl</a:To>
$security
</s:Header>
<s:Body>
<GetExtendedUpdateInfo2 xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
<updateIDs>
<UpdateIdentity><UpdateID>$UpdateId</UpdateID><RevisionNumber>$Revision</RevisionNumber></UpdateIdentity>
</updateIDs>
<infoTypes>
<XmlUpdateFragmentType>FileUrl</XmlUpdateFragmentType>
<XmlUpdateFragmentType>FileDecryption</XmlUpdateFragmentType>
</infoTypes>
<deviceAttributes>$($script:DeviceAttributes)</deviceAttributes>
</GetExtendedUpdateInfo2>
</s:Body>
</s:Envelope>
"@
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $WuSecuredUrl -Method Post -Body $body -ContentType 'application/soap+xml; charset=utf-8'
    [xml]$xml = $resp.Content
    return $xml
}

function Get-LatestAppleMusicBundleUrl {
    Write-Host '[*] Resolving the Apple Music catalog entry on Microsoft Update servers...'
    $categoryId = Get-WuCategoryId -ProductId $StoreProductId
    Write-Host "    WuCategoryId = $categoryId"

    $cookie = Get-WuCookie
    $syncXml = Get-SyncUpdatesXml -CategoryId $categoryId -Cookie $cookie

    $ns = New-Object System.Xml.XmlNamespaceManager($syncXml.NameTable)
    $ns.AddNamespace('wu', 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService')
    $extUpdates = $syncXml.SelectNodes('//wu:ExtendedUpdateInfo/wu:Updates/wu:Update', $ns)
    $newUpdates = $syncXml.SelectNodes('//wu:NewUpdates/wu:UpdateInfo', $ns)

    # Among all historical Apple Music x64/neutral msixbundle entries
    # Microsoft's catalog knows about, pick the one with the highest
    # version -- that is always the current release.
    $targetNumericId = $null
    $bestVersion = $null
    $bestVersionStr = $null
    foreach ($eu in $extUpdates) {
        if ($eu.OuterXml -notmatch '\.msixbundle') { continue }
        if ($eu.OuterXml -notmatch [regex]::Escape($OrigPackageName) + '_([\d\.]+)_neutral_~_\w+') { continue }
        $verStr = $Matches[1]
        try { $ver = [System.Version]$verStr } catch { continue }
        if (-not $bestVersion -or $ver -gt $bestVersion) {
            $bestVersion = $ver
            $bestVersionStr = $verStr
            $targetNumericId = $eu.ID
        }
    }
    if (-not $targetNumericId) {
        throw 'Could not find an Apple Music .msixbundle entry in the Microsoft Update catalog response.'
    }
    Write-Host "    Latest catalog version: $bestVersionStr"

    $targetGuid = $null
    $targetRevision = $null
    foreach ($u in $newUpdates) {
        if ($u.ID -ne $targetNumericId) { continue }
        $innerXmlText = $u.Xml.InnerXml
        if (-not $innerXmlText) { continue }
        [xml]$inner = "<root>$innerXmlText</root>"
        $targetGuid = $inner.root.UpdateIdentity.UpdateID
        $targetRevision = $inner.root.UpdateIdentity.RevisionNumber
    }
    if (-not $targetGuid) {
        throw 'Could not correlate the catalog entry with an UpdateIdentity.'
    }

    $fileUrlXml = Get-FileUrlsXml -UpdateId $targetGuid -Revision $targetRevision
    $ns2 = New-Object System.Xml.XmlNamespaceManager($fileUrlXml.NameTable)
    $ns2.AddNamespace('wu', 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService')
    $fileLocations = $fileUrlXml.SelectNodes('//wu:FileLocations/wu:FileLocation', $ns2)

    $downloadUrl = $null
    foreach ($fl in $fileLocations) {
        $u = $fl.SelectSingleNode('wu:Url', $ns2).InnerText
        # Prefer the signed CDN edge URL (tlu.dl.delivery.mp.microsoft.com)
        # over the generic filestreamingservice one; both work, but the
        # signed one is the one Microsoft's own clients use by default.
        if ($u -match '^https?://tlu\.') { $downloadUrl = $u }
    }
    if (-not $downloadUrl -and $fileLocations.Count -gt 0) {
        $downloadUrl = $fileLocations[0].SelectSingleNode('wu:Url', $ns2).InnerText
    }
    if (-not $downloadUrl) {
        throw 'Microsoft Update servers returned no download URL for the current Apple Music package.'
    }

    [pscustomobject]@{ Url = $downloadUrl; Version = $bestVersionStr }
}

# ---------------------------------------------------------------------------
# Step 1: unpack the bundle, patch, and install.
# ---------------------------------------------------------------------------

function Unpack-AppleMusicBundle {
    param([string]$BundlePath, [string]$DestDir)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $DestDir) { Remove-Item -Recurse -Force $DestDir }
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

    $bundleZip = [System.IO.Compression.ZipFile]::OpenRead($BundlePath)
    try {
        $x64Entry = $bundleZip.Entries | Where-Object { $_.Name -match '(?i)_x64\.msix$' } | Select-Object -First 1
        if (-not $x64Entry) { throw 'Could not find an x64 .msix inside the bundle.' }
        Write-Host "    Found x64 package inside the bundle: $($x64Entry.Name)"

        $tempMsix = Join-Path $env:TEMP "applemusic_x64_$([guid]::NewGuid().ToString('N')).msix"
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($x64Entry, $tempMsix, $true)
        try {
            $msixZip = [System.IO.Compression.ZipFile]::OpenRead($tempMsix)
            try {
                foreach ($entry in $msixZip.Entries) {
                    if ($entry.Name -eq '' ) { continue } # directory entry
                    $targetPath = Join-Path $DestDir $entry.FullName
                    $targetDir = Split-Path $targetPath -Parent
                    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
                }
            } finally { $msixZip.Dispose() }
        } finally {
            Remove-Item $tempMsix -Force -ErrorAction SilentlyContinue
        }
    } finally {
        $bundleZip.Dispose()
    }
}

function Remove-SignatureFiles {
    param([string]$PkgDir)
    foreach ($rel in $SignatureFilesToRemove) {
        $p = Join-Path $PkgDir $rel
        if (Test-Path $p) {
            Remove-Item $p -Force
            Write-Host "    [-] Removed signature file: $rel"
        }
    }
}

function Patch-Manifest {
    param([string]$PkgDir)
    $manifestPath = Join-Path $PkgDir 'AppxManifest.xml'
    $text = Get-Content -Raw -Encoding UTF8 $manifestPath

    if ($text -match [regex]::Escape($OrigPackageName)) {
        $text = $text -replace ('(<Identity\s+[^>]*?Name=")' + [regex]::Escape($OrigPackageName) + '(")'), ('${1}' + $NewPackageName + '${2}')
        Write-Host "    [+] AppxManifest.xml: Identity Name changed $OrigPackageName -> $NewPackageName"
    } elseif ($text -match [regex]::Escape($NewPackageName)) {
        Write-Host "    [=] AppxManifest.xml: Identity Name is already $NewPackageName"
    } else {
        throw "Could not find <Identity Name=`"$OrigPackageName`"> in AppxManifest.xml"
    }

    $before = $text
    $text = $text -replace 'MinVersion="10\.0\.\d+\.\d+"', ('MinVersion="' + $TargetMinVersion + '"')
    Write-Host "    [+] AppxManifest.xml: set MinVersion=`"$TargetMinVersion`""

    Set-Content -Path $manifestPath -Value $text -Encoding UTF8 -NoNewline
}

function Patch-AmpUtils {
    param([string]$PkgDir)
    $dllPath = Join-Path $PkgDir 'AMP.Utils.dll'
    $bytes = [System.IO.File]::ReadAllBytes($dllPath)

    # --- Minimal PE32+ export table parser (inline, no external module) ---
    if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw 'AMP.Utils.dll is not a valid PE file (missing MZ).' }
    $eLfanew = [BitConverter]::ToUInt32($bytes, 0x3C)
    $coffOffset = $eLfanew + 4
    $numSections = [BitConverter]::ToUInt16($bytes, $coffOffset + 2)
    $sizeOptHdr = [BitConverter]::ToUInt16($bytes, $coffOffset + 16)
    $optOffset = $coffOffset + 20
    $magic = [BitConverter]::ToUInt16($bytes, $optOffset)
    if ($magic -eq 0x20B) { $exportDirOffset = $optOffset + 112 }
    elseif ($magic -eq 0x10B) { $exportDirOffset = $optOffset + 96 }
    else { throw "Unsupported PE OptionalHeader magic: 0x$($magic.ToString('X'))" }
    $exportRva = [BitConverter]::ToUInt32($bytes, $exportDirOffset)
    $exportSize = [BitConverter]::ToUInt32($bytes, $exportDirOffset + 4)

    $secTableOffset = $optOffset + $sizeOptHdr
    $sections = @()
    for ($i = 0; $i -lt $numSections; $i++) {
        $off = $secTableOffset + $i * 40
        $virtSize = [BitConverter]::ToUInt32($bytes, $off + 8)
        $virtAddr = [BitConverter]::ToUInt32($bytes, $off + 12)
        $rawSize = [BitConverter]::ToUInt32($bytes, $off + 16)
        $rawPtr = [BitConverter]::ToUInt32($bytes, $off + 20)
        $sections += [pscustomobject]@{ VA = $virtAddr; VS = $virtSize; Ptr = $rawPtr; RS = $rawSize }
    }
    function Rva2Off([uint32]$rva) {
        foreach ($s in $sections) {
            $span = [Math]::Max($s.VS, $s.RS)
            if ($rva -ge $s.VA -and $rva -lt ($s.VA + $span)) { return $s.Ptr + ($rva - $s.VA) }
        }
        throw "Could not translate RVA 0x$($rva.ToString('X')) to a file offset"
    }

    $patchedOffsets = New-Object 'System.Collections.Generic.HashSet[uint32]'
    $patchBytes = [byte[]](0xB0, 0x01, 0xC3) # mov al, 1; ret

    if ($exportRva -ne 0 -and $exportSize -ne 0) {
        $expOff = Rva2Off $exportRva
        $numNames = [BitConverter]::ToUInt32($bytes, $expOff + 24)
        $addrFuncsRva = [BitConverter]::ToUInt32($bytes, $expOff + 28)
        $addrNamesRva = [BitConverter]::ToUInt32($bytes, $expOff + 32)
        $addrOrdsRva = [BitConverter]::ToUInt32($bytes, $expOff + 36)
        $funcsOff = Rva2Off $addrFuncsRva
        $namesOff = Rva2Off $addrNamesRva
        $ordsOff = Rva2Off $addrOrdsRva

        for ($i = 0; $i -lt $numNames; $i++) {
            $nameRva = [BitConverter]::ToUInt32($bytes, $namesOff + $i * 4)
            $ordIdx = [BitConverter]::ToUInt16($bytes, $ordsOff + $i * 2)
            $funcRva = [BitConverter]::ToUInt32($bytes, $funcsOff + $ordIdx * 4)
            if ($funcRva -ge $exportRva -and $funcRva -lt ($exportRva + $exportSize)) { continue } # forwarded export

            $namePos = Rva2Off $nameRva
            $end = $namePos
            while ($bytes[$end] -ne 0) { $end++ }
            $name = [System.Text.Encoding]::ASCII.GetString($bytes, $namePos, $end - $namePos)

            if ($name -like '*IsMachineWindows11*') {
                $fo = Rva2Off $funcRva
                [Array]::Copy($patchBytes, 0, $bytes, $fo, 3)
                [void]$patchedOffsets.Add($fo)
                Write-Host "    [+] Patched export $name (FileOff 0x$($fo.ToString('X'))) -> B0 01 C3"
            }
        }
    }

    # Byte-signature fallback: catches the same OS-build-number check even
    # if it isn't exported under a recognizable name in a future build.
    # See docs/root-cause-analysis.md for the exact instruction shape.
    $sigPattern = [byte[]](0x48,0x83,0xEC,0x38,0x48,0x8D,0x4C,0x24,0x20)
    for ($i = 0; $i -le $bytes.Length - 30; $i++) {
        if ($patchedOffsets.Contains([uint32]$i)) { continue }
        $match = $true
        for ($j = 0; $j -lt $sigPattern.Length; $j++) {
            if ($bytes[$i + $j] -ne $sigPattern[$j]) { $match = $false; break }
        }
        if (-not $match) { continue }
        if ($bytes[$i+9] -ne 0xE8) { continue }
        if ($bytes[$i+14] -ne 0x81 -or $bytes[$i+15] -ne 0x7C -or $bytes[$i+16] -ne 0x24 -or $bytes[$i+17] -ne 0x20) { continue }
        $buildNum = [BitConverter]::ToUInt16($bytes, $i+18)
        if ($bytes[$i+20] -ne 0 -or $bytes[$i+21] -ne 0) { continue }
        if ($bytes[$i+22] -ne 0x0F -or $bytes[$i+23] -ne 0x93 -or $bytes[$i+24] -ne 0xC0) { continue }
        if ($bytes[$i+25] -ne 0x48 -or $bytes[$i+26] -ne 0x83 -or $bytes[$i+27] -ne 0xC4 -or $bytes[$i+28] -ne 0x38) { continue }
        if ($bytes[$i+29] -ne 0xC3) { continue }
        if ($buildNum -lt 21996 -or $buildNum -gt 30000) { continue }
        [Array]::Copy($patchBytes, 0, $bytes, $i, 3)
        [void]$patchedOffsets.Add([uint32]$i)
        Write-Host "    [+] Patched by signature (build >= $buildNum check, FileOff 0x$($i.ToString('X'))) -> B0 01 C3"
    }

    if ($patchedOffsets.Count -eq 0) {
        Write-Host '    [!] WARNING: no unpatched Windows-11 version check found.'
    }

    # Patch the embedded UTF-16LE package-name string.
    $origU16 = [System.Text.Encoding]::Unicode.GetBytes($OrigPackageName)
    $newU16 = [System.Text.Encoding]::Unicode.GetBytes($NewPackageName)
    $strCount = 0
    $pos = 0
    while ($true) {
        $idx = -1
        for ($i = $pos; $i -le $bytes.Length - $origU16.Length; $i++) {
            $m = $true
            for ($j = 0; $j -lt $origU16.Length; $j++) { if ($bytes[$i+$j] -ne $origU16[$j]) { $m = $false; break } }
            if ($m) { $idx = $i; break }
        }
        if ($idx -eq -1) { break }
        [Array]::Copy($newU16, 0, $bytes, $idx, $newU16.Length)
        $strCount++
        Write-Host "    [+] Patched UTF-16LE package string at offset 0x$($idx.ToString('X')): $OrigPackageName -> $NewPackageName"
        $pos = $idx + $newU16.Length
    }
    if ($strCount -eq 0) {
        Write-Host "    [=] UTF-16LE string $NewPackageName already present (or not found) in AMP.Utils.dll"
    }

    [System.IO.File]::WriteAllBytes($dllPath, $bytes)
}

function Register-ApplePackage {
    param([string]$PkgDir)
    $manifestPath = Join-Path $PkgDir 'AppxManifest.xml'

    # Destructive cleanup only ever targets the *original* Apple package
    # identity -- the one with the broken StateRepository entry described
    # in docs/root-cause-analysis.md. Our own renamed package
    # (NewPackageName) is intentionally left alone here: Add-AppxPackage
    # -Register below re-registers it in place, which Windows treats as an
    # update of the same app and keeps its LocalState / Apple ID sign-in
    # data intact.
    $origPkg = Get-AppxPackage "$OrigPackageName*" -ErrorAction SilentlyContinue
    if ($origPkg) {
        Write-Host "[*] Removing the broken stock registration ($OrigPackageName) -- first-run migration only..."
        $origPkg | Remove-AppxPackage -ErrorAction SilentlyContinue
    }

    Write-Host "[*] Registering package from $manifestPath ..."
    try {
        Add-AppxPackage -Register $manifestPath -ErrorAction Stop
    } catch {
        throw "Add-AppxPackage -Register failed: $($_.Exception.Message)"
    }
    Write-Host '[+] Package registered successfully.'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ('=' * 68)
Write-Host 'AppleMusicForW10 installer'
Write-Host ('=' * 68)

Write-Host '[*] Stopping running Apple Music processes...'
Get-Process AppleMusic, AMPLibraryAgent -ErrorAction SilentlyContinue | Stop-Process -Force

$workDir = Join-Path $env:TEMP "AppleMusicForW10_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$bundlePath = Join-Path $workDir 'AppleMusic.msixbundle'

try {
    $info = Get-LatestAppleMusicBundleUrl
    Write-Host "[*] Downloading Apple Music $($info.Version) directly from Microsoft's CDN..."
    Invoke-WebRequest -UseBasicParsing -Uri $info.Url -OutFile $bundlePath

    Write-Host '[*] Unpacking the x64 package...'
    Unpack-AppleMusicBundle -BundlePath $bundlePath -DestDir $Dest

    Write-Host '[*] Cleaning up MSIX signature files...'
    Remove-SignatureFiles -PkgDir $Dest

    Write-Host '[*] Patching AppxManifest.xml...'
    Patch-Manifest -PkgDir $Dest

    Write-Host '[*] Patching AMP.Utils.dll (exports + signatures + package string)...'
    Patch-AmpUtils -PkgDir $Dest

    Register-ApplePackage -PkgDir $Dest

    if ($Launch) {
        Write-Host '[*] Launching Apple Music...'
        Start-Process "shell:AppsFolder\$($NewPackageName)_nzyj5cx40ttqa!App"
    }

    Write-Host '[+] Done! Installed to:' $Dest
} finally {
    if (-not $KeepDownload) {
        Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
    } else {
        Write-Host "[*] Kept working files in: $workDir"
    }
}
