// =============================================================================
// AI Foundry account module — STRUCTURAL FIX for issue #26
// =============================================================================
// This is a customized derivation of the AVM PTN ai-foundry@0.6.0 account
// submodule. It addresses the long-standing race condition between
// `Microsoft.CognitiveServices/accounts` provisioning and the dependent
// private endpoint deployment, also tracked upstream in
// Azure/bicep-registry-modules#5957.
//
// ROOT CAUSE
// ----------
// `Microsoft.CognitiveServices/accounts` PUT returns HTTP 200 synchronously
// with `provisioningState: Accepted` and transitions to `Succeeded`
// asynchronously WITHOUT returning a real LRO. Bicep/ARM consider the parent
// resource "deployed" after the sync 200, so any dependent private endpoint
// PUT runs while the account is still in `Accepted`, raising
// `AccountProvisioningStateInvalid`.
//
// FIX STRUCTURE
// -------------
// 1. Pass `privateEndpoints: []` to `avm/res/cognitive-services/account`
//    so the AVM resource module does NOT create the PE inline.
// 2. Provision a small user-assigned identity and grant it `Reader` on the
//    cog-svc account.
// 3. Run a `Microsoft.Resources/deploymentScripts` (AzPowerShell) that polls
//    `Get-AzCognitiveServicesAccount` until `provisioningState == Succeeded`
//    (max ~10 minutes).
// 4. Create the private endpoint via `avm/res/network/private-endpoint` with
//    an explicit `dependsOn` on the wait script.
//
// History on this repo:
//   - PR  #19  — original property-matching pre-create workaround
//   - Issue #25 — first regression (networkInjections)
//   - Issue #26 — second regression (networkAcls.bypass) → this fix
//   - Issue #27 — upstream tracking
// =============================================================================

@description('Required. The name of the AI Foundry resource.')
param name string

@description('Required. The location for the AI Foundry resource.')
param location string

@description('Optional. SKU of the AI Foundry / Cognitive Services account. Use \'Get-AzCognitiveServicesAccountSku\' to determine a valid combinations of \'kind\' and \'SKU\' for your Azure region.')
@allowed([
  'C2'
  'C3'
  'C4'
  'F0'
  'F1'
  'S'
  'S0'
  'S1'
  'S10'
  'S2'
  'S3'
  'S4'
  'S5'
  'S6'
  'S7'
  'S8'
  'S9'
  'DC0'
])
param sku string = 'S0'

@description('Required. Whether to allow project management in AI Foundry. This is required to enable the AI Foundry UI and project management features.')
param allowProjectManagement bool

@description('Optional. Resource Id of an existing subnet to use for private connectivity. This is required along with \'privateDnsZoneResourceIds\' to establish private endpoints.')
param privateEndpointSubnetResourceId string?

@description('Optional. Resource Id of an existing subnet to use for agent connectivity. This is required when using agents with private endpoints.')
param agentSubnetResourceId string?

@description('Required. Allow only Azure AD authentication. Should be enabled for security reasons.')
param disableLocalAuth bool

import { roleAssignmentType } from 'br/public:avm/utl/types/avm-common-types:0.6.1'
@description('Optional. Specifies the role assignments for the AI Foundry resource.')
param roleAssignments roleAssignmentType[]?

import { lockType } from 'br/public:avm/utl/types/avm-common-types:0.6.1'
@description('Optional. The lock settings of AI Foundry resources.')
param lock lockType?

import { deploymentType } from 'br/public:avm/res/cognitive-services/account:0.13.2'
@description('Optional. Specifies the OpenAI deployments to create.')
param aiModelDeployments deploymentType[] = []

@description('Optional. List of private DNS zone resource IDs to use for the AI Foundry resource. This is required when using private endpoints.')
param privateDnsZoneResourceIds string[]?

@description('Optional. Enable/Disable usage telemetry for module.')
param enableTelemetry bool = true

@description('Optional. Specifies the resource tags for all the resources.')
param tags resourceInput<'Microsoft.Resources/resourceGroups@2025-04-01'>.tags = {}

var privateDnsZoneResourceIdValues = [
  for id in privateDnsZoneResourceIds ?? []: {
    privateDnsZoneResourceId: id
  }
]
var privateNetworkingEnabled = !empty(privateDnsZoneResourceIdValues) && !empty(privateEndpointSubnetResourceId)

// Built-in role definition IDs
var readerRoleDefinitionId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

// -----------------------------------------------------------------------------
// 1. Cognitive Services account (no inline PE — fix for #26)
// -----------------------------------------------------------------------------
module foundryAccount 'br/public:avm/res/cognitive-services/account:0.13.2' = {
  name: take('avm.res.cognitive-services.account.${name}', 64)
  params: {
    name: name
    location: location
    tags: tags
    sku: sku
    kind: 'AIServices'
    lock: lock
    allowProjectManagement: allowProjectManagement
    managedIdentities: {
      systemAssigned: true
    }
    deployments: aiModelDeployments
    customSubDomainName: name
    disableLocalAuth: disableLocalAuth
    publicNetworkAccess: privateNetworkingEnabled ? 'Disabled' : 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    networkInjections: privateNetworkingEnabled && !empty(agentSubnetResourceId)
      ? {
          scenario: 'agent'
          subnetResourceId: agentSubnetResourceId!
          useMicrosoftManagedNetwork: false
        }
      : null
    // Issue #26: PE is created OUTSIDE this AVM module, gated on a wait script,
    // to break the race against the cog-svc provisioningState transition.
    privateEndpoints: []
    enableTelemetry: enableTelemetry
    roleAssignments: roleAssignments
  }
}

// -----------------------------------------------------------------------------
// 2. Existing reference (for use by wait script + PE)
// -----------------------------------------------------------------------------
resource accountExisting 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: name
}

// -----------------------------------------------------------------------------
// 3. UAI for the wait script (only when private networking enabled)
// -----------------------------------------------------------------------------
resource accountWaitUai 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (privateNetworkingEnabled) {
  name: take('id-aifwait-${name}', 128)
  location: location
  tags: tags
}

// -----------------------------------------------------------------------------
// 4. Reader role assignment for the UAI on the cog-svc account
// -----------------------------------------------------------------------------
resource accountWaitUaiReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (privateNetworkingEnabled) {
  name: guid(accountExisting.id, readerRoleDefinitionId, 'aifwait')
  scope: accountExisting
  properties: {
    principalId: accountWaitUai!.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleDefinitionId)
  }
  dependsOn: [
    foundryAccount
  ]
}

// -----------------------------------------------------------------------------
// 5. Wait deploymentScript — polls account.provisioningState until Succeeded
// -----------------------------------------------------------------------------
resource accountWaitScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = if (privateNetworkingEnabled) {
  name: take('ds-aifwait-${name}', 90)
  location: location
  tags: tags
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${accountWaitUai!.id}': {}
    }
  }
  properties: {
    azPowerShellVersion: '12.3'
    retentionInterval: 'PT1H'
    timeout: 'PT15M'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      {
        name: 'RG_NAME'
        value: resourceGroup().name
      }
      {
        name: 'ACCOUNT_NAME'
        value: name
      }
    ]
    scriptContent: '''
      $ErrorActionPreference = 'Stop'
      $maxAttempts = 60
      $delaySeconds = 10
      $attempt = 0
      $state = ''
      while ($attempt -lt $maxAttempts) {
        $attempt++
        try {
          $acct = Get-AzCognitiveServicesAccount -ResourceGroupName $env:RG_NAME -Name $env:ACCOUNT_NAME -ErrorAction Stop
          $state = $acct.ProvisioningState
          Write-Output "Attempt $attempt/$maxAttempts — provisioningState: $state"
          if ($state -eq 'Succeeded') {
            $DeploymentScriptOutputs = @{ provisioningState = $state; attempts = $attempt }
            return
          }
          if ($state -eq 'Failed' -or $state -eq 'Canceled') {
            throw "Account provisioning ended in terminal non-success state: $state"
          }
        } catch {
          Write-Output "Attempt $attempt/$maxAttempts — transient error: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $delaySeconds
      }
      throw "Timed out after $maxAttempts attempts; last observed state: $state"
    '''
  }
  dependsOn: [
    foundryAccount
    accountWaitUaiReader
  ]
}

// -----------------------------------------------------------------------------
// 6. Private endpoint, gated on the wait script
// -----------------------------------------------------------------------------
module accountPrivateEndpoint 'br/public:avm/res/network/private-endpoint:0.11.0' = if (privateNetworkingEnabled) {
  name: take('pe.${name}.account', 64)
  params: {
    name: 'pep-${name}-account'
    location: location
    tags: tags
    subnetResourceId: privateEndpointSubnetResourceId!
    privateLinkServiceConnections: [
      {
        name: 'pep-${name}-account'
        properties: {
          privateLinkServiceId: accountExisting.id
          groupIds: [
            'account'
          ]
        }
      }
    ]
    privateDnsZoneGroup: {
      privateDnsZoneGroupConfigs: privateDnsZoneResourceIdValues
    }
  }
  dependsOn: [
    accountWaitScript
  ]
}

@description('Name of the AI Foundry resource.')
output name string = foundryAccount.outputs.name

@description('Resource ID of the AI Foundry resource.')
output resourceId string = foundryAccount.outputs.resourceId

@description('Subscription ID of the AI Foundry resource.')
output subscriptionId string = subscription().subscriptionId

@description('Resource Group Name of the AI Foundry resource.')
output resourceGroupName string = resourceGroup().name

@description('Location of the AI Foundry resource.')
output location string = location

@description('System assigned managed identity principal ID of the AI Foundry resource.')
output systemAssignedMIPrincipalId string = foundryAccount!.outputs.systemAssignedMIPrincipalId!
