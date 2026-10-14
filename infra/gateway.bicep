// API Management and the reminder Logic App of the Fee Management System.
//
// Deploy AFTER infra/main.bicep and after the Function code (npm run deploy): API Management reads
// the Function's host key, which only exists once the Function host has started with code.
//
//   az deployment group create -g rg-feemgmt-eastasia -f infra/gateway.bicep //     -p feeApiClientId=<Fee API appId> publisherEmail=<your email>
//
// Afterwards: give the Logic App identity the Reminders.Read role (scripts/entra-setup.ps1
// -ReminderPrincipalId <logicAppPrincipalId output>) and authorize the Outlook connection once.

@description('Azure region; the same as the core resources.')
param location string = resourceGroup().location

@description('Short project name used in every resource name (the same as in main.bicep).')
@minLength(3)
@maxLength(12)
param appName string = 'feemgmt'

@description('The suffix used in main.bicep.')
@minLength(6)
@maxLength(6)
param suffix string = 'k7x2pq'

@description('Application (client) ID of the "Fee API" app registration, printed by scripts/entra-setup.ps1.')
param feeApiClientId string

@description('Email shown as the API publisher in API Management (required by Azure). Your own email.')
param publisherEmail string

// The core resources from main.bicep.
resource functionApp 'Microsoft.Web/sites@2024-04-01' existing = {
  name: 'func-${appName}-${suffix}'
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: 'appi-${appName}-${suffix}'
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: 'log-${appName}-${suffix}'
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

output feeApiBaseUrl string = '${apim.properties.gatewayUrl}/${feeApi.properties.path}'
output logicAppName string = reminderWorkflow.name
output logicAppPrincipalId string = reminderWorkflow.identity.principalId
