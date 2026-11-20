// PLS-077: the worker identity may read exactly this Application Insights component — nothing
// wider (guide step 4.1). Deployed in the component's own resource group, which may differ from
// the instance's.
param appInsightsName string
param workerPrincipalId string

resource appi 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

var roles = {
  logAnalyticsDataReader: '3b03c2da-16b3-4a49-8834-0f8130efdd3b'
  monitoringReader: '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
}

resource readers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for role in items(roles): {
    name: guid(appi.id, workerPrincipalId, role.value)
    scope: appi
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.value)
      principalId: workerPrincipalId
      principalType: 'ServicePrincipal'
    }
  }
]
