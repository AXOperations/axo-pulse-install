// PLS-094 / PLS-077: one customer-hosted AXO Pulse instance (model b).
//
// Creates, in the customer's resource group:
//   - two user-assigned identities (web, worker) — no client secrets anywhere
//   - a VNet with Postgres (VNet-integrated) and Key Vault (private endpoint) reachable only from it
//   - Key Vault (RBAC, purge protection) holding DATABASE_URL and the optional Jira token
//   - a Container Apps environment (workload profiles, VNet) logging to the customer's workspace
//   - the web app (HTTPS ingress) and the worker (no ingress) from the imported, signed image
//   - the Entra login app, its four roles, its service principal (assignment required) and a
//     federated credential for the web identity (Microsoft Graph Bicep extension)
//   - read access for the worker identity on the Application Insights component
//
// Run through deploy.sh, which deploys registry.bicep and imports the image first.
targetScope = 'resourceGroup'

extension microsoftGraphV1

@description('Short customer name used in resource names, e.g. contoso. Same value as for registry.bicep.')
@minLength(2)
@maxLength(12)
param shortName string

param location string = resourceGroup().location

@description('Resource ID of the Application Insights component from guide step 1.5.')
param appInsightsResourceId string

@description('Name of the registry from registry.bicep, holding the imported image.')
param registryName string

@description('Digest of the verified AXO Pulse image, sha256:<64 hex>.')
@minLength(71)
@maxLength(71)
param imageDigest string

@description('Version shown in the app, e.g. 0.1.0.')
param appVersion string

@description('AX Operations\' Entra tenant ID — users from it get the vendor role.')
param vendorTenantId string = 'a0267be7-ffe5-4383-af6e-aabd58bb14f9'

@description('Scoped Jira token for AX Operations\' feedback project (supplied by AX Operations). Empty: feedback is kept in the instance but not delivered.')
@secure()
param jiraApiToken string = ''

@description('Minimum web replicas. 0 scales to zero when nobody uses it (cheaper, a few seconds\' cold start).')
@minValue(0)
@maxValue(3)
param webMinReplicas int = 0

@description('Address space for the instance VNet. Change it if it overlaps a network you will peer with.')
param vnetAddressPrefix string = '10.80.0.0/22'

@description('Generated on every deployment: the database password is rotated and both apps restart.')
@secure()
param databasePassword string = newGuid()

param deployedAt string = utcNow()

@description('Tags applied to every Azure resource this template creates (not to the Microsoft Graph objects).')
param tags object = {}

@description('Optional. Resource ID of an existing central private DNS zone for Postgres (hub-and-spoke, may be in another subscription/resource group). A VNet-integrated flexible server needs a zone whose name ends in .private.postgres.database.azure.com — not the privatelink.postgres.database.azure.com zone used for private endpoints. Empty: the zone is created in this resource group. Set: the deploying user needs Private DNS Zone Contributor on that zone to create the VNet link.')
param postgresPrivateDnsZoneId string = ''

@description('Optional. Resource ID of an existing central privatelink.vaultcore.azure.net zone. Empty: created in this resource group. Set: the deploying user needs Private DNS Zone Contributor on that zone to create the VNet link.')
param keyVaultPrivateDnsZoneId string = ''

@description('Optional. Name of an existing (e.g. point-in-time restored) Postgres server to adopt; the deployment then updates that server. Empty: the generated name.')
param postgresServerName string = ''

var suffix = take(uniqueString(resourceGroup().id), 6)
var compactName = replace(shortName, '-', '')
var names = {
  vnet: 'vnet-axopulse-${shortName}'
  idWeb: 'id-axopulse-web'
  idWorker: 'id-axopulse-worker'
  keyVault: take('kv-axopulse-${compactName}-${suffix}', 24)
  postgres: 'psql-axopulse-${shortName}-${suffix}'
  environment: 'cae-axopulse-${shortName}'
  web: 'ca-axopulse-web'
  worker: 'ca-axopulse-worker'
  loginApp: 'axo-pulse-${shortName}'
}
var postgresName = empty(postgresServerName) ? names.postgres : postgresServerName
var databaseName = 'axopulse'
var databaseAdmin = 'axopulseadmin'
var appiParts = split(appInsightsResourceId, '/')
var useCentralPostgresDns = !empty(postgresPrivateDnsZoneId)
var useCentralKeyVaultDns = !empty(keyVaultPrivateDnsZoneId)
// Resource ID layout: /subscriptions/<sub>/resourceGroups/<rg>/providers/.../privateDnsZones/<zone>.
// The ternaries keep the index expressions safe while the parameter is empty.
var postgresDnsParts = split(postgresPrivateDnsZoneId, '/')
var keyVaultDnsParts = split(keyVaultPrivateDnsZoneId, '/')
var image = '${acr.properties.loginServer}/axo-pulse@${imageDigest}'
var tenantId = tenant().tenantId
var roleIds = {
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
}
var pulseRoles = [
  { value: 'Pulse.AxoAdmin', displayName: 'AXO Pulse AXO-admin', description: 'AXO-admin' }
  { value: 'Pulse.Consultant', displayName: 'AXO Pulse konsulent', description: 'Konsulent' }
  { value: 'Pulse.CustomerAdmin', displayName: 'AXO Pulse kunde-admin', description: 'Kunde-admin' }
  { value: 'Pulse.CustomerReader', displayName: 'AXO Pulse kunde-læser', description: 'Kunde-læser' }
]

// ---------------------------------------------------------------- existing inputs

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: registryName
}

resource appi 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appiParts[8]
  scope: resourceGroup(appiParts[2], appiParts[4])
}

// ---------------------------------------------------------------- identities

resource idWeb 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: names.idWeb
  location: location
  tags: tags
}

resource idWorker 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: names.idWorker
  location: location
  tags: tags
}

var identities = [
  { key: 'web', principalId: idWeb.properties.principalId }
  { key: 'worker', principalId: idWorker.properties.principalId }
]

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (id, i) in [names.idWeb, names.idWorker]: {
    name: guid(acr.id, id, roleIds.acrPull)
    scope: acr
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.acrPull)
      principalId: identities[i].principalId
      principalType: 'ServicePrincipal'
    }
  }
]

module appiAccess 'modules/appinsights-access.bicep' = {
  name: 'axopulse-appinsights-access'
  scope: resourceGroup(appiParts[2], appiParts[4])
  params: {
    appInsightsName: appiParts[8]
    workerPrincipalId: idWorker.properties.principalId
  }
}

// ---------------------------------------------------------------- network

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: names.vnet
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [vnetAddressPrefix] }
    subnets: [
      {
        name: 'snet-apps'
        properties: {
          addressPrefix: cidrSubnet(vnetAddressPrefix, 24, 0)
          delegations: [{ name: 'apps', properties: { serviceName: 'Microsoft.App/environments' } }]
        }
      }
      {
        name: 'snet-postgres'
        properties: {
          addressPrefix: cidrSubnet(vnetAddressPrefix, 27, 8)
          delegations: [{ name: 'postgres', properties: { serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers' } }]
        }
      }
      {
        name: 'snet-endpoints'
        properties: {
          addressPrefix: cidrSubnet(vnetAddressPrefix, 27, 9)
        }
      }
    ]
  }
}

// Private DNS: created here unless the customer supplies an existing central zone (Azure Policy in
// hub-and-spoke landing zones often forbids private DNS zones in spoke resource groups). A supplied
// zone only gets a VNet link from this template, via a module scoped to the zone's own resource group;
// the deploying user then needs Private DNS Zone Contributor on that central zone.

resource postgresDns 'Microsoft.Network/privateDnsZones@2024-06-01' = if (!useCentralPostgresDns) {
  name: '${names.postgres}.private.postgres.database.azure.com'
  location: 'global'
  tags: tags
}

resource postgresDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (!useCentralPostgresDns) {
  parent: postgresDns
  name: names.vnet
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

module postgresDnsLinkCentral 'modules/dns-zone-link.bicep' = if (useCentralPostgresDns) {
  name: 'axopulse-postgres-dns-link'
  scope: resourceGroup(
    useCentralPostgresDns ? postgresDnsParts[2] : subscription().subscriptionId,
    useCentralPostgresDns ? postgresDnsParts[4] : resourceGroup().name
  )
  params: {
    zoneName: useCentralPostgresDns ? postgresDnsParts[8] : 'unused'
    linkName: names.vnet
    vnetId: vnet.id
    tags: tags
  }
}

resource keyVaultDns 'Microsoft.Network/privateDnsZones@2024-06-01' = if (!useCentralKeyVaultDns) {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: tags
}

resource keyVaultDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (!useCentralKeyVaultDns) {
  parent: keyVaultDns
  name: names.vnet
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

module keyVaultDnsLinkCentral 'modules/dns-zone-link.bicep' = if (useCentralKeyVaultDns) {
  name: 'axopulse-keyvault-dns-link'
  scope: resourceGroup(
    useCentralKeyVaultDns ? keyVaultDnsParts[2] : subscription().subscriptionId,
    useCentralKeyVaultDns ? keyVaultDnsParts[4] : resourceGroup().name
  )
  params: {
    zoneName: useCentralKeyVaultDns ? keyVaultDnsParts[8] : 'unused'
    linkName: names.vnet
    vnetId: vnet.id
    tags: tags
  }
}

var postgresDnsZoneId = useCentralPostgresDns ? postgresPrivateDnsZoneId : postgresDns.id
var keyVaultDnsZoneId = useCentralKeyVaultDns ? keyVaultPrivateDnsZoneId : keyVaultDns.id

// ---------------------------------------------------------------- Postgres

resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: postgresName
  location: location
  tags: tags
  sku: { name: 'Standard_B1ms', tier: 'Burstable' }
  properties: {
    version: '17'
    administratorLogin: databaseAdmin
    administratorLoginPassword: databasePassword
    authConfig: { passwordAuth: 'Enabled', activeDirectoryAuth: 'Disabled' }
    storage: { storageSizeGB: 32, autoGrow: 'Enabled' }
    backup: { backupRetentionDays: 14, geoRedundantBackup: 'Disabled' }
    highAvailability: { mode: 'Disabled' }
    network: {
      delegatedSubnetResourceId: vnet.properties.subnets[1].id
      privateDnsZoneArmResourceId: postgresDnsZoneId
      publicNetworkAccess: 'Disabled'
    }
  }
  dependsOn: [postgresDnsLink, postgresDnsLinkCentral]
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: postgres
  name: databaseName
  properties: { charset: 'UTF8', collation: 'en_US.utf8' }
}

// ---------------------------------------------------------------- Key Vault

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: names.keyVault
  location: location
  tags: tags
  properties: {
    tenantId: tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'AzureServices' }
  }
}

resource keyVaultEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${names.keyVault}'
  location: location
  tags: tags
  properties: {
    subnet: { id: vnet.properties.subnets[2].id }
    privateLinkServiceConnections: [
      {
        name: 'vault'
        properties: { privateLinkServiceId: keyVault.id, groupIds: ['vault'] }
      }
    ]
  }
}

resource keyVaultEndpointDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: keyVaultEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [{ name: 'vault', properties: { privateDnsZoneId: keyVaultDnsZoneId } }]
  }
}

resource databaseUrlSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'database-url'
  properties: {
    value: 'postgres://${databaseAdmin}:${databasePassword}@${postgres.properties.fullyQualifiedDomainName}:5432/${databaseName}'
  }
}

resource jiraSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(jiraApiToken)) {
  parent: keyVault
  name: 'jira-api-token'
  properties: { value: jiraApiToken }
}

resource secretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (id, i) in [names.idWeb, names.idWorker]: {
    name: guid(keyVault.id, id, roleIds.keyVaultSecretsUser)
    scope: keyVault
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.keyVaultSecretsUser)
      principalId: identities[i].principalId
      principalType: 'ServicePrincipal'
    }
  }
]

// ---------------------------------------------------------------- Container Apps environment

resource appsEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: names.environment
  location: location
  tags: tags
  properties: {
    workloadProfiles: [{ name: 'Consumption', workloadProfileType: 'Consumption' }]
    vnetConfiguration: {
      infrastructureSubnetId: vnet.properties.subnets[0].id
      internal: false
    }
    appLogsConfiguration: { destination: 'azure-monitor' }
  }
}

resource environmentDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-customer-workspace'
  scope: appsEnv
  properties: {
    workspaceId: appi.properties.WorkspaceResourceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}

var webFqdn = '${names.web}.${appsEnv.properties.defaultDomain}'
var baseUrl = 'https://${webFqdn}'

// ---------------------------------------------------------------- Entra login app (guide step 5.1)

resource loginApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: names.loginApp
  displayName: 'AXO Pulse'
  signInAudience: 'AzureADMyOrg'
  groupMembershipClaims: 'ApplicationGroup'
  web: { redirectUris: ['${baseUrl}/auth/callback'] }
  optionalClaims: {
    idToken: [{ name: 'groups', essential: false }]
    accessToken: [{ name: 'groups', essential: false }]
  }
  appRoles: [
    for role in pulseRoles: {
      id: guid(resourceGroup().id, names.loginApp, role.value)
      allowedMemberTypes: ['User']
      displayName: role.displayName
      description: role.description
      value: role.value
      isEnabled: true
    }
  ]
}

// The Graph extension wants the credential's name as '{application uniqueName}/{credential}'.
resource webCredential 'Microsoft.Graph/applications/federatedIdentityCredentials@v1.0' = {
  name: '${loginApp.uniqueName}/axopulse-web'
  issuer: '${environment().authentication.loginEndpoint}${tenantId}/v2.0'
  subject: idWeb.properties.principalId
  audiences: ['api://AzureADTokenExchange']
}

resource loginServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: loginApp.appId
  appRoleAssignmentRequired: true
  // Without this tag the app is missing from Entra's default "Enterprise applications" list,
  // where the guide sends the admin to assign roles (step 5.3). HideApp keeps it off My Apps.
  tags: ['WindowsAzureActiveDirectoryIntegratedApp', 'HideApp']
}

// ---------------------------------------------------------------- apps

var commonEnv = [
  { name: 'NODE_ENV', value: 'production' }
  { name: 'APP_VERSION', value: appVersion }
  { name: 'APP_BASE_URL', value: baseUrl }
  { name: 'AZURE_TENANT_ID', value: tenantId }
  { name: 'APPINSIGHTS_RESOURCE_ID', value: appi.id }
  { name: 'VENDOR_TENANT_ID', value: vendorTenantId }
  { name: 'FEEDBACK_TRANSPORT', value: 'jira' }
  { name: 'DATABASE_URL', secretRef: 'database-url' }
  { name: 'DEPLOYED_AT', value: deployedAt }
]

resource web 'Microsoft.App/containerApps@2024-03-01' = {
  name: names.web
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${idWeb.id}': {} }
  }
  properties: {
    environmentId: appsEnv.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8090
        transport: 'auto'
        allowInsecure: false
      }
      registries: [{ server: acr.properties.loginServer, identity: idWeb.id }]
      // PLS-129: the web app gets the Jira token too — the vendor settings page (AX Operations users only)
      // shows whether it exists and runs "Test forbindelse". The token can only create issues in AX
      // Operations' feedback project; the worker still does the actual delivery.
      secrets: concat(
        [{ name: 'database-url', keyVaultUrl: databaseUrlSecret.properties.secretUri, identity: idWeb.id }],
        empty(jiraApiToken) ? [] : [{ name: 'jira-api-token', keyVaultUrl: jiraSecret!.properties.secretUri, identity: idWeb.id }]
      )
    }
    template: {
      containers: [
        {
          name: 'web'
          image: image
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: concat(
            commonEnv,
            [
              { name: 'PORT', value: '8090' }
              { name: 'AZURE_CLIENT_ID', value: idWeb.properties.clientId }
              { name: 'AUTH_MODE', value: 'entra' }
              { name: 'AUTH_TENANT_ID', value: tenantId }
              { name: 'AUTH_CLIENT_ID', value: loginApp.appId }
              { name: 'AUTH_MANAGED_IDENTITY_CLIENT_ID', value: idWeb.properties.clientId }
            ],
            empty(jiraApiToken) ? [] : [{ name: 'JIRA_API_TOKEN', secretRef: 'jira-api-token' }]
          )
        }
      ]
      scale: { minReplicas: webMinReplicas, maxReplicas: 2 }
    }
  }
  dependsOn: [acrPull, secretsUser, keyVaultEndpointDns, loginServicePrincipal, webCredential]
}

resource worker 'Microsoft.App/containerApps@2024-03-01' = {
  name: names.worker
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${idWorker.id}': {} }
  }
  properties: {
    environmentId: appsEnv.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      registries: [{ server: acr.properties.loginServer, identity: idWorker.id }]
      secrets: concat(
        [{ name: 'database-url', keyVaultUrl: databaseUrlSecret.properties.secretUri, identity: idWorker.id }],
        empty(jiraApiToken) ? [] : [{ name: 'jira-api-token', keyVaultUrl: jiraSecret!.properties.secretUri, identity: idWorker.id }]
      )
    }
    template: {
      containers: [
        {
          name: 'worker'
          image: image
          command: ['bun', 'run', '--cwd', 'worker', 'start']
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: concat(
            commonEnv,
            [{ name: 'AZURE_CLIENT_ID', value: idWorker.properties.clientId }],
            empty(jiraApiToken) ? [] : [{ name: 'JIRA_API_TOKEN', secretRef: 'jira-api-token' }]
          )
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
  dependsOn: [acrPull, secretsUser, keyVaultEndpointDns, database, appiAccess]
}

// ---------------------------------------------------------------- outputs (guide step 3)

output webUrl string = baseUrl
output webIdentityClientId string = idWeb.properties.clientId
output workerIdentityClientId string = idWorker.properties.clientId
output workerIdentityPrincipalId string = idWorker.properties.principalId
output loginAppClientId string = loginApp.appId
output keyVaultName string = keyVault.name
