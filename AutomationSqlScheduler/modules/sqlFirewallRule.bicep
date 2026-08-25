// Optional firewall rule on an EXISTING Azure SQL logical server allowing
// Azure services and resources to access the server (0.0.0.0-0.0.0.0 magic
// range recognized by Azure SQL). This is a convenience/compat rule; it does
// NOT restrict access to your own tenant/subscription resources only — any
// Azure-hosted resource (including other customers') could potentially reach
// the server's public endpoint if firewall/identity checks are misconfigured
// downstream. Prefer Private Endpoints/VNet rules for production-grade
// isolation. This module is opt-in (deployIt = false by default is decided by
// the parent template through conditional module deployment).
@description('Name of the existing Azure SQL logical server.')
param sqlServerName string

@description('Name for the "Allow Azure services" firewall rule.')
param firewallRuleName string = 'AllowAllWindowsAzureIps'

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' existing = {
  name: sqlServerName
}

resource allowAzureServices 'Microsoft.Sql/servers/firewallRules@2023-08-01' = {
  parent: sqlServer
  name: firewallRuleName
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

output ruleName string = allowAzureServices.name
