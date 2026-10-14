// Azure resources for the Fee Management System.
//
// Deploy into the existing resource group (see docs/DEPLOYMENT.md):
//   az deployment group create -g rg-feemgmt-eastasia -f infra/main.bicep \
//     -p sqlAdminLogin=<your-upn> sqlAdminObjectId=<your-object-id>
//
// Passwordless by design:
//   - The Function App has a system-assigned managed identity.
//   - Storage has account-key access disabled; the app reaches it through its identity.
//   - Azure SQL accepts only Microsoft Entra sign-ins. The deploying user is its admin and
//     grants the app's identity access with sql/005_grant_function.sql.

@description('Azure region. The subscription policy allows only a few regions; the SQL free offer is fixed to East Asia.')
param location string = resourceGroup().location

@description('Short project name used in every resource name. Lowercase letters and digits only (storage names allow no hyphens).')
@minLength(3)
@maxLength(12)
param appName string = 'feemgmt'

@description('Random suffix that makes the public DNS names (Function App, SQL server, storage, APIM) globally unique.')
@minLength(6)
@maxLength(6)
param suffix string = 'k7x2pq'

@description('User principal name of the Entra user who administers the SQL server (you).')
param sqlAdminLogin string

@description('Object ID of that Entra user.')
param sqlAdminObjectId string

@description('Time zone that decides which day "today" is for due dates.')
param feeTimeZone string = 'Asia/Kolkata'

@description('Application (client) ID of the "Fee API" app registration, printed by scripts/entra-setup.ps1. Tokens must be issued for it.')
param feeApiClientId string

@description('Email shown as the API publisher in API Management (required by Azure). Your own email.')
param publisherEmail string

var functionAppName = 'func-${appName}-${suffix}'
var storageAccountName = 'st${appName}${suffix}'
var sqlServerName = 'sql-${appName}-${suffix}'
var sqlDatabaseName = 'FeeManagement'
var deploymentContainerName = 'deployment-package'

// ---------------------------------------------------------------- Monitoring

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${appName}-${suffix}'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    // Hard ceiling on ingestion per day, so telemetry can never eat into the credit.
    workspaceCapping: { dailyQuotaGb: json('0.1') }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${appName}-${suffix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ---------------------------------------------------------------- Storage (Functions host + deployment package)

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    allowSharedKeyAccess: false // identity only: no account keys to leak
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deploymentContainerName
}

// ---------------------------------------------------------------- Function App (Flex Consumption)

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'plan-${appName}-${suffix}'
  location: location
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true // Linux
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        // Functions host storage, reached with the app's identity instead of a connection string.
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        // Database: no user or password, the app signs in with its managed identity.
        { name: 'SQL_SERVER', value: '${sqlServerName}${environment().suffixes.sqlServerHostname}' }
        { name: 'SQL_DATABASE', value: sqlDatabaseName }
        { name: 'FEE_TIMEZONE', value: feeTimeZone }
        // The Function checks every token itself: issued by this tenant, for the Fee API.
        { name: 'ENTRA_TENANT_ID', value: subscription().tenantId }
        { name: 'ENTRA_API_CLIENT_ID', value: feeApiClientId }
      ]
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 512
        // Caps scale-out so a burst of traffic cannot exhaust a 1-vCore database's connections.
        maximumInstanceCount: 40
      }
      runtime: {
        name: 'node'
        version: '24'
      }
    }
  }
}

// HTTP-only app: the host needs blob access only (deployment package and host locks).
// Built-in role ID: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles
var storageBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'

resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, functionApp.id, storageBlobDataOwner)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwner)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------- Azure SQL (free offer)

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'User'
      login: sqlAdminLogin
      sid: sqlAdminObjectId
      tenantId: subscription().tenantId
      azureADOnlyAuthentication: true // SQL logins and passwords are disabled entirely
    }
  }
}

// Lets Azure services (including this Function App, whose outbound IPs change) reach the server.
// Access still requires an Entra identity that has been granted a database user.
resource allowAzureServices 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: sqlDatabaseName
  location: location
  sku: {
    name: 'GP_S_Gen5'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 1 // maximum vCores
  }
  properties: {
    useFreeLimit: true
    freeLimitExhaustionBehavior: 'AutoPause' // pause until next month rather than bill
    minCapacity: json('0.5')
    // Minutes idle before pausing. Free-offer databases reject the general serverless minimum of 15.
    autoPauseDelay: 60
    maxSizeBytes: 34359738368 // 32 GB, the free-offer limit
    requestedBackupStorageRedundancy: 'Local'
    zoneRedundant: false
  }
}

// ---------------------------------------------------------------- API Management (Consumption)
// Callers use https://<apim>.azure-api.net/fees/... with an API key (Ocp-Apim-Subscription-Key)
// and an Entra ID token. Policies live in infra/apim/*.xml so they can be read on their own.

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: 'apim-${appName}-${suffix}'
  location: location
  sku: {
    name: 'Consumption'
    capacity: 0
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: 'Fee Management System'
  }
}

resource nvTenantId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'entra-tenant-id'
  properties: {
    displayName: 'entra-tenant-id'
    value: subscription().tenantId
  }
}

resource nvFeeApiClientId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'fee-api-client-id'
  properties: {
    displayName: 'fee-api-client-id'
    value: feeApiClientId
  }
}

// The Function App's host key, read at deployment time and stored encrypted. It never appears in
// the repo or in outputs; only API Management sends it, so the Function cannot be called around it.
resource nvFunctionKey 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'function-key'
  properties: {
    displayName: 'function-key'
    secret: true
    // sites/host is the real path of a Function App's host keys; the linter's type list lacks it.
    #disable-next-line use-recognized-resource-type
    value: listKeys(resourceId('Microsoft.Web/sites/host', functionApp.name, 'default'), '2024-04-01').functionKeys.default
  }
}

resource feeApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'fee-api'
  properties: {
    displayName: 'Fee API'
    path: 'fees'
    protocols: ['https']
    serviceUrl: 'https://${functionApp.properties.defaultHostName}/api'
    subscriptionRequired: true // the API key
    subscriptionKeyParameterNames: {
      header: 'Ocp-Apim-Subscription-Key'
      query: 'subscription-key'
    }
  }
}

resource feeApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: feeApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('apim/api-policy.xml')
  }
  dependsOn: [nvTenantId, nvFeeApiClientId, nvFunctionKey]
}

var idParameter = [{ name: 'id', type: 'integer', required: true }]
var operations = [
  {
    name: 'get-student-fees'
    displayName: 'Get a student\'s fee details and payment status'
    method: 'GET'
    urlTemplate: '/students/{id}/fees'
    templateParameters: idParameter
    policy: loadTextContent('apim/roles-student-or-admin.xml')
  }
  {
    name: 'list-students'
    displayName: 'List students (FeeAdmin), optionally by status'
    method: 'GET'
    urlTemplate: '/students'
    templateParameters: []
    policy: loadTextContent('apim/roles-fee-admin.xml')
  }
  {
    name: 'update-student-fees'
    displayName: 'Update a student\'s fee record (FeeAdmin)'
    method: 'PATCH'
    urlTemplate: '/students/{id}'
    templateParameters: idParameter
    policy: loadTextContent('apim/roles-fee-admin.xml')
  }
  {
    name: 'list-overdue'
    displayName: 'List overdue students (Logic App only)'
    method: 'GET'
    urlTemplate: '/reminders/overdue'
    templateParameters: []
    policy: loadTextContent('apim/roles-reminders.xml')
  }
]

resource feeApiOperations 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = [
  for op in operations: {
    parent: feeApi
    name: op.name
    properties: {
      displayName: op.displayName
      method: op.method
      urlTemplate: op.urlTemplate
      templateParameters: op.templateParameters
    }
  }
]

resource feeApiOperationPolicies 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = [
  for (op, i) in operations: {
    parent: feeApiOperations[i]
    name: 'policy'
    properties: {
      format: 'rawxml'
      value: op.policy
    }
    dependsOn: [nvTenantId, nvFeeApiClientId]
  }
]

resource product 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  parent: apim
  name: 'fee-management'
  properties: {
    displayName: 'Fee Management'
    description: 'Student fee status and administration API.'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource productApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: product
  name: feeApi.name
}

// Two API keys with separate rate-limit counters, so a demo burst cannot block the reminders.
// Their keys are generated by Azure and read with `az rest` (see docs/DEPLOYMENT.md), never output.
resource subscriptionPostman 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apim
  name: 'postman-demo'
  properties: {
    displayName: 'Postman demo (students and administrators)'
    scope: product.id
    state: 'active'
  }
}

resource subscriptionLogicApp 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apim
  name: 'logic-app'
  properties: {
    displayName: 'Reminder Logic App'
    scope: product.id
    state: 'active'
  }
}

// Request logs to Application Insights: status codes and timings only. Bodies and headers are not
// logged (0 bytes), because they contain names, emails, fees, tokens and keys.
resource apimLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'appinsights'
  properties: {
    loggerType: 'applicationInsights'
    resourceId: appInsights.id
    credentials: {
      instrumentationKey: appInsights.properties.InstrumentationKey
    }
  }
}

var noBodies = {
  request: { headers: [], body: { bytes: 0 } }
  response: { headers: [], body: { bytes: 0 } }
}

resource feeApiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: feeApi
  name: 'applicationinsights'
  properties: {
    loggerId: apimLogger.id
    alwaysLog: 'allErrors'
    sampling: { samplingType: 'fixed', percentage: 100 }
    verbosity: 'information'
    logClientIp: false
    httpCorrelationProtocol: 'W3C'
    frontend: noBodies
    backend: noBodies
  }
}

// ---------------------------------------------------------------- Reminders: Logic App + Office 365 Outlook
// The workflow (infra/logicapp/workflow.json) runs daily at 09:00 India time, asks the Fee API who
// is overdue, and emails each student. It signs in to the API with its own managed identity, which
// scripts/entra-setup.ps1 -ReminderPrincipalId gives the Reminders.Read role.

// The Outlook connection. Microsoft allows this connector only with a person's sign-in, so after the
// first deployment you authorize it once in the portal (docs/DEPLOYMENT.md); emails go from that mailbox.
resource office365Connection 'Microsoft.Web/connections@2016-06-01' = {
  name: 'office365'
  location: location
  properties: {
    displayName: 'Office 365 Outlook (fee reminders)'
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'office365')
    }
  }
}

resource reminderWorkflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: 'logic-${appName}-${suffix}'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    state: 'Enabled'
    definition: loadJsonContent('logicapp/workflow.json')
    parameters: {
      '$connections': {
        value: {
          office365: {
            connectionId: office365Connection.id
            connectionName: office365Connection.name
            id: office365Connection.properties.api.id
          }
        }
      }
      apimBaseUrl: { value: '${apim.properties.gatewayUrl}/${feeApi.properties.path}' }
      apimKey: { value: subscriptionLogicApp.listSecrets().primaryKey } // SecureString: hidden in run history
      feeApiAudience: { value: 'api://${feeApiClientId}' }
    }
  }
  dependsOn: [productApi, feeApiOperationPolicies]
}

// Run history goes to the same Log Analytics workspace as the Function and API Management.
resource reminderWorkflowDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: reminderWorkflow
  name: 'to-log-analytics'
  properties: {
    workspaceId: logAnalytics.id
    logs: [{ category: 'WorkflowRuntime', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

// ---------------------------------------------------------------- Outputs

output logicAppName string = reminderWorkflow.name
output logicAppPrincipalId string = reminderWorkflow.identity.principalId
output apimGatewayUrl string = apim.properties.gatewayUrl
output feeApiBaseUrl string = '${apim.properties.gatewayUrl}/${feeApi.properties.path}'
output functionAppName string = functionApp.name
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output functionPrincipalId string = functionApp.identity.principalId
output sqlServerName string = sqlServer.name
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = sqlDatabase.name
output storageAccountName string = storage.name
output appInsightsName string = appInsights.name
