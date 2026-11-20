// PLS-094: the customer's own container registry. Deployed before main.bicep so the signed
// AXO Pulse image can be imported into it (deploy.sh) before the Container Apps reference it.
targetScope = 'resourceGroup'

@description('Short customer name used in resource names, e.g. contoso.')
@minLength(2)
@maxLength(12)
param shortName string

param location string = resourceGroup().location

@description('Tags applied to the registry.')
param tags object = {}

// deploy.sh passes the same optional parameters file (-P) to this template and to main.bicep. An ARM
// deployment rejects keys the template does not declare, so the main.bicep-only keys are accepted here
// and ignored.
@description('Ignored here; used by main.bicep.')
#disable-next-line no-unused-params
param postgresPrivateDnsZoneId string = ''

@description('Ignored here; used by main.bicep.')
#disable-next-line no-unused-params
param keyVaultPrivateDnsZoneId string = ''

var suffix = take(uniqueString(resourceGroup().id), 6)

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'cr${replace(shortName, '-', '')}${suffix}'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
  }
}

output registryName string = acr.name
output loginServer string = acr.properties.loginServer
