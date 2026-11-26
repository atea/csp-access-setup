#Requires -Version 5.1

<#

.SYNOPSIS

  Preview or remove Partner Center reseller relationships listed in

  "Tenant IDs and customer names.csv".

.DESCRIPTION

  Reads WorkbookRow, Customer Name, TenantId. Preview is the default.

  -Execute sends one PATCH per eligible tenant after an explicit batch confirmation.

  This does not delete customer tenants or verify live subscription/purchase eligibility.

.EXAMPLE

  .\Remove-PartnerRelationships.ps1 -CsvPath '.\Tenant IDs and customer names.csv'

.EXAMPLE

  $env:PARTNER_CENTER_ACCESS_TOKEN = '<App+User Partner Center access token>'

  .\Remove-PartnerRelationships.ps1 -CsvPath '.\Tenant IDs and customer names.csv' -Execute -Limit 1

#>

[CmdletBinding()]

param(

    [Parameter(Mandatory = $true)] [string] $CsvPath,

    [string] $ReportPath = (Join-Path (Get-Location).Path ('RelationshipRemoval-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')),

    [switch] $Execute,

    [ValidateRange(1, 1000000)] [int] $Limit = 1000000

)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) { throw "CSV not found: $CsvPath" }

if ([IO.Path]::GetFullPath($CsvPath) -eq [IO.Path]::GetFullPath($ReportPath)) { throw 'ReportPath must differ from CsvPath.' }

$rows = @(Import-Csv -LiteralPath $CsvPath -Encoding UTF8)

if ($rows.Count -eq 0) { throw 'CSV has no data rows.' }

$required = @('WorkbookRow', 'Customer Name', 'TenantId')

foreach ($field in $required) {

    if ($field -notin $rows[0].PSObject.Properties.Name) { throw "Missing CSV column: $field" }

}

# Preflight the entire input; never act on a duplicate or unnamed tenant.

$seen = @{}

$work = foreach ($row in $rows) {

    $name = ([string]$row.'Customer Name').Trim()

    $id = ([string]$row.TenantId).Trim()

    $reason = ''

    $parsed = [guid]::Empty

    if (-not [guid]::TryParse($id, [ref]$parsed) -or $parsed -eq [guid]::Empty) {

        $reason = 'Missing or invalid TenantId'

    } elseif ([string]::IsNullOrWhiteSpace($name)) {

        $reason = 'Missing customer name: review source row before removal'

    } else {

        $id = $parsed.ToString()

        if ($seen.ContainsKey($id)) { $reason = 'Duplicate TenantId: skipped' }

        else { $seen[$id] = $true }

    }

    [pscustomobject]@{ WorkbookRow = $row.WorkbookRow; CustomerName = $name; TenantId = $id; Reason = $reason }

}

$eligible = @($work | Where-Object { -not $_.Reason } | Select-Object -First $Limit)

$eligibleIds = @{}

foreach ($item in $eligible) { $eligibleIds[$item.TenantId] = $true }

$mode = 'Preview'

if ($Execute) {

    $token = $env:PARTNER_CENTER_ACCESS_TOKEN

    if ([string]::IsNullOrWhiteSpace($token)) {

        throw 'Set PARTNER_CENTER_ACCESS_TOKEN to a valid Partner Center App+User access token before using -Execute.'

    }

    if ($eligible.Count -eq 0) { throw 'No eligible rows to process.' }

    Write-Host "Ready to PATCH $($eligible.Count) reseller relationships. CSV: $CsvPath"

    Write-Host 'Check all subscription and purchase prerequisites independently before proceeding.'

    $confirmation = Read-Host "Type REMOVE $($eligible.Count) to proceed"

    if ($confirmation -cne "REMOVE $($eligible.Count)") { throw 'Cancelled; no PATCH requests sent.' }

    $mode = 'Execute'

}

$body = '{"relationshipToPartner":"none","attributes":{"objectType":"Customer"}}'

$results = foreach ($item in $work) {

    $status = 'Preview'

    $detail = 'No API request sent'

    $requestId = ''

    $correlationId = ''

    if ($item.Reason) {

        $status = 'Skipped'; $detail = $item.Reason

    } elseif (-not $eligibleIds.ContainsKey($item.TenantId)) {

        $status = 'NotSelected'; $detail = 'Beyond -Limit; no API request sent'

    } elseif ($Execute) {

        $requestId = [guid]::NewGuid().ToString()

        $correlationId = [guid]::NewGuid().ToString()

        $headers = @{

            Authorization = "Bearer $token"

            Accept = 'application/json'

            'MS-RequestId' = $requestId

            'MS-CorrelationId' = $correlationId

        }

        try {

            $response = Invoke-WebRequest -Uri (https://api.partnercenter.microsoft.com/v1/customers/{0} -f $item.TenantId) `

                -Method Patch -Headers $headers -ContentType 'application/json; charset=utf-8' `

                -Body $body -UseBasicParsing -ErrorAction Stop

            $returned = $response.Content | ConvertFrom-Json

            if ([int]$response.StatusCode -ne 200 -or $returned.relationshipToPartner -ne 'none') {

                throw 'Response did not confirm HTTP 200 and relationshipToPartner=none.'

            }

            $status = 'Success'; $detail = 'Reseller relationship removed'

        } catch {

            $status = 'Failed'

            $detail = $_.Exception.Message

            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {

                $detail = 'HTTP ' + [int]$_.Exception.Response.StatusCode + ': ' + $detail

            }

        }

    }

    [pscustomobject]@{

        WorkbookRow = $item.WorkbookRow

        CustomerName = $item.CustomerName

        TenantId = $item.TenantId

        Mode = $mode

        Status = $status

        Details = $detail

        RequestId = $requestId

        CorrelationId = $correlationId

    }

}

$results | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8

$results | Group-Object Status | Select-Object Name, Count | Format-Table -AutoSize

Write-Host "Report: $ReportPath"