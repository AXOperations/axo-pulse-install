// Links the instance VNet to an EXISTING private DNS zone (a central hub zone, possibly in another
// subscription or resource group). Deployed with scope = the zone's resource group. The deploying
// user needs Private DNS Zone Contributor on the zone.
param zoneName string
param linkName string
param vnetId string
param tags object = {}

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: zoneName
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: linkName
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: { id: vnetId }
    registrationEnabled: false
  }
}
