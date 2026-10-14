<#
.SYNOPSIS
  Creates the Microsoft Entra ID pieces of the Fee Management System. Safe to re-run.

  - "Fee API" app registration: App ID URI api://<appId>, v2 tokens, scope access_as_user,
    app roles FeeAdmin and Student (people) and Reminders.Read (the Logic App).
  - "Fee Client" app registration: a public client Postman signs in through
    (authorization code + PKCE, no secret).
  - Pre-authorizes Fee Client and Azure CLI on the scope, so nobody is asked for consent.
  - Assigns roles: you -> FeeAdmin, -StudentObjectIds -> Student, -ReminderPrincipalId -> Reminders.Read.

.EXAMPLE
  ./scripts/entra-setup.ps1
  ./scripts/entra-setup.ps1 -StudentObjectIds <guest-oid-1>,<guest-oid-2>
  ./scripts/entra-setup.ps1 -ReminderPrincipalId <logic-app-identity-object-id>
#>
param(
    [string[]] $StudentObjectIds = @(),
    [string]   $ReminderPrincipalId = ''
)
$ErrorActionPreference = 'Stop'

# Fixed IDs: re-runs must reuse them, or existing role assignments would point at removed roles.
$ScopeId         = 'dd9ae816-9f9f-40c8-805f-469dfde978d6' # access_as_user
$FeeAdminRoleId  = 'c182b166-f7a4-495f-a634-abbb1dd8d923'
$StudentRoleId   = '1f2488a8-ffa0-4cea-9617-83a984d22fee'
$RemindersRoleId = 'e9786e08-5ca0-4501-b7f7-deecc8d3b4cb'
$AzureCliAppId   = '04b07795-8ddb-461a-bbee-02f9e1bf7b46' # Microsoft's Azure CLI, the fallback client
$PostmanCallback = 'https://oauth.pstmn.io/v1/callback'
$Graph           = 'https://graph.microsoft.com/v1.0'

# Runs az, stops on failure, returns the parsed JSON output (or $null when there is none).
function Invoke-Az {
    $out = & az @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed:`n$out" }
    $text = ($out | Out-String).Trim()
    if ($text) { $text | ConvertFrom-Json } else { $null }
}

# Calls Microsoft Graph. The body goes through a temp file because PowerShell 5.1 mangles
# double quotes in arguments passed to native programs.
function Invoke-Graph([string] $Method, [string] $Url, $Body = $null) {
    if ($null -eq $Body) { return Invoke-Az rest --method $Method --url $Url }
    $file = New-TemporaryFile
    [IO.File]::WriteAllText($file.FullName, ($Body | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
    try { Invoke-Az rest --method $Method --url $Url --headers 'Content-Type=application/json' --body "@$($file.FullName)" }
    finally { Remove-Item $file.FullName }
}

function Get-OrCreateApp([string] $Name) {
    $found = Invoke-Az ad app list --display-name $Name --query '[0]'
    if ($found) { Write-Host "found app '$Name'"; return $found }
    Write-Host "creating app '$Name'"
    Invoke-Az ad app create --display-name $Name --sign-in-audience AzureADMyOrg
}

function Get-OrCreateServicePrincipal([string] $AppId) {
    $sp = Invoke-Az ad sp list --filter "appId eq '$AppId'" --query '[0]'
    if ($sp) { return $sp }
    Invoke-Az ad sp create --id $AppId
}

function Grant-AppRole([string] $ResourceSpId, [string] $PrincipalId, [string] $RoleId, [string] $Label) {
    $existing = Invoke-Graph GET "$Graph/servicePrincipals/$ResourceSpId/appRoleAssignedTo?`$top=999"
    if ($existing.value | Where-Object { $_.principalId -eq $PrincipalId -and $_.appRoleId -eq $RoleId }) {
        Write-Host "  $Label (already assigned)"; return
    }
    Invoke-Graph POST "$Graph/servicePrincipals/$ResourceSpId/appRoleAssignedTo" @{
        principalId = $PrincipalId; resourceId = $ResourceSpId; appRoleId = $RoleId
    } | Out-Null
    Write-Host "  $Label (assigned)"
}

# ---------------------------------------------------------------- 1. Fee API (the protected resource)
$api = Get-OrCreateApp 'Fee API'
$scope = @{
    id = $ScopeId; value = 'access_as_user'; type = 'User'; isEnabled = $true
    adminConsentDisplayName = 'Access the Fee API'
    adminConsentDescription = 'Call the Fee Management API as the signed-in user.'
    userConsentDisplayName  = 'Access the Fee API'
    userConsentDescription  = 'Call the Fee Management API as you.'
}
Invoke-Graph PATCH "$Graph/applications/$($api.id)" @{
    identifierUris = @("api://$($api.appId)")
    api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = @($scope) }
    appRoles = @(
        @{ id = $FeeAdminRoleId; value = 'FeeAdmin'; displayName = 'Fee administrator'; isEnabled = $true
           description = 'Query any student and update fee records.'; allowedMemberTypes = @('User') },
        @{ id = $StudentRoleId; value = 'Student'; displayName = 'Student'; isEnabled = $true
           description = 'Read your own fee details and payment status.'; allowedMemberTypes = @('User') },
        @{ id = $RemindersRoleId; value = 'Reminders.Read'; displayName = 'Reminder workflow'; isEnabled = $true
           description = 'Read the list of overdue students (the Logic App).'; allowedMemberTypes = @('Application') }
    )
} | Out-Null
$apiSp = Get-OrCreateServicePrincipal $api.appId

# ---------------------------------------------------------------- 2. Fee Client (what Postman signs in through)
$client = Get-OrCreateApp 'Fee Client'
Invoke-Graph PATCH "$Graph/applications/$($client.id)" @{
    publicClient = @{ redirectUris = @($PostmanCallback) }
    requiredResourceAccess = @(@{ resourceAppId = $api.appId; resourceAccess = @(@{ id = $ScopeId; type = 'Scope' }) })
} | Out-Null
Get-OrCreateServicePrincipal $client.appId | Out-Null

# ---------------------------------------------------------------- 3. Pre-authorize the clients (no consent prompt)
# Sent as a second update because the scope must exist before clients can be pre-authorized for it.
# The whole api object is sent again so the scope and token version are kept.
Invoke-Graph PATCH "$Graph/applications/$($api.id)" @{
    api = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes = @($scope)
        preAuthorizedApplications = @(
            @{ appId = $client.appId; delegatedPermissionIds = @($ScopeId) },
            @{ appId = $AzureCliAppId; delegatedPermissionIds = @($ScopeId) }
        )
    }
} | Out-Null

# ---------------------------------------------------------------- 4. Role assignments
$me = Invoke-Az ad signed-in-user show
Write-Host 'Role assignments on Fee API:'
Grant-AppRole $apiSp.id $me.id $FeeAdminRoleId "FeeAdmin -> $($me.userPrincipalName)"
foreach ($oid in $StudentObjectIds) { Grant-AppRole $apiSp.id $oid $StudentRoleId "Student -> $oid" }
if ($ReminderPrincipalId) { Grant-AppRole $apiSp.id $ReminderPrincipalId $RemindersRoleId "Reminders.Read -> $ReminderPrincipalId" }

# ---------------------------------------------------------------- Values the later phases need
$tenantId = (Invoke-Az account show).tenantId
Write-Host ''
Write-Host "Tenant ID        : $tenantId"
Write-Host "Fee API appId    : $($api.appId)   (token audience; scope api://$($api.appId)/access_as_user)"
Write-Host "Fee Client appId : $($client.appId)"
