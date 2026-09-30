# PEC Customer Role Assignment Script
# Run in Azure Cloud Shell (PowerShell mode) - no login required

$roles = @("Support Request Contributor", "Quota Request Operator")

$adminAgentGroupObjectIds = @(
    "d2bbd7ab-3014-484e-9690-fbd3b3ac19dc", # Old T1 Admin Agent
    "bbe02849-3866-4d29-b07b-a825aa4059cc", # New T1 Admin Agent
    "8445f4e6-defb-45c1-bb96-7282b3509eb3", # New T2 AppXite Admin Agent
    "40e635f4-59e9-41c3-a265-c829a30e015a" # New T2 Atea Admin Agent
)
$context    = Get-AzContext
$tenantId   = $context.Tenant.Id
$accountId  = $context.Account.Id

Write-Host "`n=== Azure Role Assignment Script ===" -ForegroundColor Cyan
Write-Host "Connected as : $accountId" -ForegroundColor Cyan
Write-Host "Tenant ID    : $tenantId`n" -ForegroundColor Cyan

$currentUserId = $null
try {
    # Bruker Az PowerShell sin egen påloggingstoken mot Microsoft Graph i stedet for Azure
    # CLI ('az'), som ikke alltid er separat autentisert i en Cloud Shell-økt selv om Az er det.
    $graphToken = (Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com" -ErrorAction Stop).Token
    if ($graphToken -is [System.Security.SecureString]) { $graphToken = [System.Net.NetworkCredential]::new('', $graphToken).Password }
    $me = Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/me?$select=id' -Headers @{ Authorization = "Bearer $graphToken" } -Method Get -ErrorAction Stop
    $currentUserId = $me.id
} catch {
    $currentUserId = $null
}

if ([string]::IsNullOrEmpty($currentUserId)) {
    Write-Host "[ABORT] Could not resolve signed-in user Object ID via Microsoft Graph." -ForegroundColor Red
    Write-Host "Run 'Disconnect-AzAccount' followed by 'Connect-AzAccount' and try again." -ForegroundColor Yellow
    exit
}
Write-Host "Object ID    : $currentUserId`n" -ForegroundColor Cyan

Write-Host "Scanning role assignments..." -ForegroundColor Yellow

$requiredRoles = @("Owner", "User Access Administrator")
$rootMgScope   = "/providers/Microsoft.Management/managementGroups/$tenantId"

$hasRootRole = [bool](
    Get-AzRoleAssignment -ObjectId $currentUserId -Scope $rootMgScope -ErrorAction SilentlyContinue |
    Where-Object { ($_.Scope -eq $rootMgScope -or $_.Scope -eq "/") -and $requiredRoles -contains $_.RoleDefinitionName }
)

$childMGs = @()
$descResp = Invoke-AzRestMethod -Method GET -Path "/providers/Microsoft.Management/managementGroups/$tenantId/descendants?api-version=2020-05-01" -ErrorAction SilentlyContinue
if ($descResp -and $descResp.StatusCode -eq 200) {
    $childMGs = ($descResp.Content | ConvertFrom-Json).value |
        Where-Object { $_.type -eq "/providers/Microsoft.Management/managementGroups" } |
        ForEach-Object { [PSCustomObject]@{ Name = $_.name; DisplayName = $_.properties.displayName } }
}
if ($childMGs.Count -eq 0) {
    $childMGs = Get-AzManagementGroup -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $tenantId } |
        ForEach-Object { [PSCustomObject]@{ Name = $_.Name; DisplayName = $_.DisplayName } }
}

$authorizedMGScopes = @($childMGs | Where-Object {
    $s = "/providers/Microsoft.Management/managementGroups/$($_.Name)"
    Get-AzRoleAssignment -ObjectId $currentUserId -Scope $s -ErrorAction SilentlyContinue |
        Where-Object { $_.Scope -eq $s -and $requiredRoles -contains $_.RoleDefinitionName }
} | ForEach-Object { "/providers/Microsoft.Management/managementGroups/$($_.Name)" })

$allSubscriptions = Get-AzSubscription -ErrorAction SilentlyContinue
$directSubScopes = @($allSubscriptions | Where-Object {
    $s = "/subscriptions/$($_.Id)"
    Get-AzRoleAssignment -ObjectId $currentUserId -Scope $s -ErrorAction SilentlyContinue |
        Where-Object { $_.Scope -eq $s -and $requiredRoles -contains $_.RoleDefinitionName }
} | ForEach-Object { "/subscriptions/$($_.Id)" })

if (-not $hasRootRole -and $authorizedMGScopes.Count -eq 0 -and $directSubScopes.Count -eq 0) {
    # Get-AzRoleAssignment viser kun AKTIVE tildelinger - en PIM-kvalifisert (Eligible, ikke
    # aktivert) Owner/UAA-rolle vises ikke der, så sjekk eksplisitt for det før vi gir opp helt.
    $eligibleRoleGuids = @('8e3af657-a8ff-443c-a75c-2fe8c4bcb635', '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9') # Owner, User Access Administrator
    function Test-EligibleRole($Scope) {
        try {
            $resp = Invoke-AzRestMethod -Method GET -Path "$Scope/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&`$filter=asTarget()" -ErrorAction Stop
            if ($resp.StatusCode -ne 200) { return $false }
            $items = ($resp.Content | ConvertFrom-Json).value
            return [bool]($items | Where-Object { $eligibleRoleGuids -contains ($_.properties.roleDefinitionId -split '/')[-1] })
        } catch { return $false }
    }
    $hasEligibleRole = (Test-EligibleRole $rootMgScope) -or
        ($childMGs | Where-Object { Test-EligibleRole "/providers/Microsoft.Management/managementGroups/$($_.Name)" }) -or
        ($allSubscriptions | Where-Object { Test-EligibleRole "/subscriptions/$($_.Id)" })

    if ($hasEligibleRole) {
        Write-Host "`n[ABORT] You have an ELIGIBLE (not active) Owner or User Access Administrator role via Privileged Identity Management (PIM), but it has not been activated." -ForegroundColor Red
        Write-Host "Go to Microsoft Entra ID > Privileged Identity Management > My roles > Azure resources, activate the role, then run this script again." -ForegroundColor Yellow
    } else {
        Write-Host "`n[ABORT] You have no Owner or User Access Administrator at any level." -ForegroundColor Red
        Write-Host "You need at least 'Owner' or 'User Access Administrator' at Root MG, a child MG, or a Subscription." -ForegroundColor Red
    }
    exit
}

Write-Host "`n=== Your role assignments ===" -ForegroundColor Cyan
if ($hasRootRole) { Write-Host "  [Root Group]" -ForegroundColor White }
foreach ($s in $authorizedMGScopes) {
    Write-Host "  [MG]  $(($childMGs | Where-Object { '/providers/Microsoft.Management/managementGroups/' + $_.Name -eq $s }).DisplayName)" -ForegroundColor White
}
foreach ($s in $directSubScopes) {
    Write-Host "  [Sub] $(($allSubscriptions | Where-Object { '/subscriptions/' + $_.Id -eq $s }).Name)" -ForegroundColor White
}

Write-Host "`n  1. Root Management Group"
Write-Host "  2. Management Group (child)"
Write-Host "  3. Subscription"
$levelChoice = Read-Host "`nEnter choice (1, 2 or 3)"

$targetScopes = @()
switch ($levelChoice) {
    "1" {
        if (-not $hasRootRole) {
            Write-Host "[ABORT] You do not have Owner or User Access Administrator on the Root Management Group." -ForegroundColor Red; exit
        }
        $targetScopes = @($rootMgScope)
    }
    "2" {
        $availableMGs = if ($hasRootRole) { $childMGs } else {
            $childMGs | Where-Object { $authorizedMGScopes -contains "/providers/Microsoft.Management/managementGroups/$($_.Name)" }
        }
        if ($availableMGs.Count -eq 0) {
            Write-Host "[ABORT] No child Management Groups found." -ForegroundColor Red; exit
        }
        $mgList = @($availableMGs)
        Write-Host "`nManagement Groups you can assign roles on:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $mgList.Count; $i++) { Write-Host "  $($i+1). $($mgList[$i].DisplayName)" }
        $mgIndices = (Read-Host "`nEnter number(s) separated by comma") -split "," | ForEach-Object { [int]$_.Trim() - 1 }
        $targetScopes = $mgIndices | ForEach-Object { "/providers/Microsoft.Management/managementGroups/$($mgList[$_].Name)" }
    }
    "3" {
        $availableSubs = [System.Collections.Generic.List[PSCustomObject]]::new()
        if ($hasRootRole) {
            $allSubscriptions | ForEach-Object { $availableSubs.Add([PSCustomObject]@{ Name = $_.Name; Id = $_.Id; Scope = "/subscriptions/$($_.Id)" }) }
        } else {
            foreach ($s in $authorizedMGScopes) {
                $mgName = $s -split "/" | Select-Object -Last 1
                $r = Invoke-AzRestMethod -Method GET -Path "/providers/Microsoft.Management/managementGroups/$mgName/descendants?api-version=2020-05-01" -ErrorAction SilentlyContinue
                if ($r -and $r.StatusCode -eq 200) {
                    ($r.Content | ConvertFrom-Json).value | Where-Object { $_.type -eq "/subscriptions" } |
                        ForEach-Object { $availableSubs.Add([PSCustomObject]@{ Name = $_.properties.displayName; Id = $_.name; Scope = "/subscriptions/$($_.name)" }) }
                }
            }
            foreach ($s in $directSubScopes) {
                if (-not ($availableSubs | Where-Object { $_.Scope -eq $s })) {
                    $sub = $allSubscriptions | Where-Object { $_.Id -eq ($s -replace "/subscriptions/","") }
                    if ($sub) { $availableSubs.Add([PSCustomObject]@{ Name = $sub.Name; Id = $sub.Id; Scope = $s }) }
                }
            }
        }
        if ($availableSubs.Count -eq 0) { Write-Host "[ABORT] No subscriptions available." -ForegroundColor Red; exit }
        $subList = @($availableSubs | Sort-Object Scope -Unique)
        Write-Host "`nSubscriptions you can assign roles on:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $subList.Count; $i++) { Write-Host "  $($i+1). $($subList[$i].Name)" }
        $subIndices = (Read-Host "`nEnter number(s) separated by comma") -split "," | ForEach-Object { [int]$_.Trim() - 1 }
        $targetScopes = $subIndices | ForEach-Object { $subList[$_].Scope }
    }
    default { Write-Host "[ABORT] Invalid choice '$levelChoice'." -ForegroundColor Red; exit }
}

$resolvedGroups = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($groupId in $adminAgentGroupObjectIds) {
    # All Admin Agent groups are Foreign groups (GDAP/CSP relationship) - not resolvable via
    # Graph here, so use the Object ID directly instead of an always-failing lookup.
    $resolvedGroups.Add([PSCustomObject]@{ Id = $groupId; DisplayName = $groupId })
}

$scopeLabel = @{}
foreach ($s in $targetScopes) {
    $scopeLabel[$s] = if ($s -eq $rootMgScope) { "Root Group" }
        elseif ($s -like "/providers/*") { ($childMGs | Where-Object { $_.Name -eq ($s -split "/" | Select-Object -Last 1) }).DisplayName }
        else { ($allSubscriptions | Where-Object { $_.Id -eq ($s -replace "/subscriptions/","") }).Name }
}

# Sporer om minst én tildeling lyktes per gruppe - grupper som er "Foreign group" kan mangle
# visningsnavn i Graph men fortsatt være gyldige RBAC-prinsipaler, så suksess måles på
# selve rolletildelingen, ikke på om gruppen kunne slås opp.
$groupHadSuccess = @{}
foreach ($group in $resolvedGroups) { $groupHadSuccess[$group.Id] = $false }

Write-Host "`n=== Assigning roles ===" -ForegroundColor Cyan
foreach ($s in $targetScopes) {
    Write-Host "`nScope: $($scopeLabel[$s])" -ForegroundColor Yellow
    foreach ($group in $resolvedGroups) {
        foreach ($role in $roles) {
            $existing = Get-AzRoleAssignment -ObjectId $group.Id -RoleDefinitionName $role -Scope $s -ErrorAction SilentlyContinue
            if ($existing) {
                Write-Host "  '$role' already assigned to '$($group.DisplayName)' on $($scopeLabel[$s])." -ForegroundColor Green
                $groupHadSuccess[$group.Id] = $true
            } else {
                try {
                    New-AzRoleAssignment -ObjectId $group.Id -RoleDefinitionName $role -Scope $s -ErrorAction Stop | Out-Null
                    Write-Host "  Assigned '$role' to '$($group.DisplayName)' on $($scopeLabel[$s])." -ForegroundColor Green
                    $groupHadSuccess[$group.Id] = $true
                } catch { }
            }
        }
    }
}

Write-Host "`n=== Role assignment complete ===" -ForegroundColor Cyan

$notFoundGroups = $resolvedGroups | Where-Object { -not $groupHadSuccess[$_.Id] }
if ($notFoundGroups.Count -gt 0) {
    Write-Host "`n=== Admin Agent groups NOT found - no roles were assigned ===" -ForegroundColor Yellow
    foreach ($g in $notFoundGroups) { Write-Host "  - $($g.DisplayName) ($($g.Id))" -ForegroundColor Yellow }
} else {
    Write-Host "`nAll Admin Agent groups were found and had roles assigned." -ForegroundColor Green
}
