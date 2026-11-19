// Azure side of the Drupal Imagine demo: one Ubuntu VM running Docker Compose,
// plus a Storage account whose private `backups` container holds DB/files backups.
//
//   az deployment group create -g rg-imagine-demo -f infra/main.bicep \
//     -p infra/main.parameters.json \
//     -p sshSourceIp="$(curl -s https://api.ipify.org)" \
//        sshPublicKey="$(cat ~/.ssh/imagine_demo.pub)" \
//        backupOperatorPrincipalId="$(az ad signed-in-user show --query id -o tsv)"
//
// See docs/deploy.md for the full procedure.

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Region for the VM and its network (VNet, NSG, public IP, NIC). Can differ from the storage region when VM capacity is short.')
param vmLocation string = location

@description('Short name used to derive resource names.')
param prefix string = 'imagine-demo'

@description('false = only network + storage, no public IP/NIC/VM. Lets backups storage exist while VM capacity is pending; re-run with true to add the VM.')
param deployVm bool = true

@description('true once the VM exists. Azure only accepts cloud-init (customData) when a VM is created and rejects any change later, so redeploys leave it out.')
param vmExists bool = false

@description('VM size. 2 vCPU / 4 GB (B2s, B2als_v2) is enough for nginx + php-fpm + MariaDB.')
param vmSize string = 'Standard_B2s'

@description('Availability zone for the VM and its disks ("1", "2", "3"), or empty for no zone. Useful when a size has no regional capacity.')
param zone string = ''

@description('Admin user for SSH. Password login is disabled.')
param adminUsername string = 'azureuser'

@description('Contents of the SSH public key (~/.ssh/imagine_demo.pub).')
param sshPublicKey string

@description('Public IPv4 address allowed to reach SSH (22). Just the address, no CIDR suffix.')
param sshSourceIp string

@description('Sources allowed on 80/443. Empty = Internet. Set to the Cloudflare IPv4 ranges (https://www.cloudflare.com/ips-v4) once Cloudflare fronts the site.')
param webSourcePrefixes array = []

@description('Size of the data disk mounted at /var/lib/docker.')
param dataDiskSizeGB int = 32

@description('Object id of the person who runs backups; gets Storage Blob Data Contributor so they can mint user-delegation SAS tokens. Empty = skip.')
param backupOperatorPrincipalId string = ''

@description('Days to keep backup blobs before the lifecycle policy deletes them.')
param backupRetentionDays int = 30

var vmName = 'vm-${prefix}'
var vnetName = 'vnet-${prefix}'
var subnetName = 'snet-default'
var nsgName = 'nsg-${prefix}'
var pipName = 'pip-${prefix}'
var nicName = 'nic-${prefix}'
// Storage names: 3-24 lowercase alphanumerics, globally unique.
var storageName = take('st${replace(prefix, '-', '')}${uniqueString(resourceGroup().id)}', 24)

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgName
  location: vmLocation
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-Admin'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '${sshSourceIp}/32'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      // HTTP/HTTPS: Internet until Cloudflare fronts the site, then only Cloudflare's ranges
      // (webSourcePrefixes in main.parameters.json; see docs/deploy.md).
      {
        name: 'Allow-HTTP-Web'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: empty(webSourcePrefixes) ? 'Internet' : null
          sourceAddressPrefixes: empty(webSourcePrefixes) ? null : webSourcePrefixes
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'Allow-HTTPS-Web'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: empty(webSourcePrefixes) ? 'Internet' : null
          sourceAddressPrefixes: empty(webSourcePrefixes) ? null : webSourcePrefixes
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: vmLocation
  properties: {
    addressSpace: { addressPrefixes: [ '10.40.0.0/16' ] }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.40.1.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (deployVm) {
  name: pipName
  location: vmLocation
  sku: { name: 'Standard', tier: 'Regional' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = if (deployVm) {
  name: nicName
  location: vmLocation
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: vnet.properties.subnets[0].id }
          publicIPAddress: { id: pip!.id }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = if (deployVm) {
  name: vmName
  location: vmLocation
  zones: empty(zone) ? null : [ zone ]
  // Lets the VM's daily backup (systemd timer) upload with azcopy without any stored secret.
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: { secureBootEnabled: true, vTpmEnabled: true }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: vmExists ? null : base64(loadTextContent('cloud-init.yaml'))
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
        patchSettings: { patchMode: 'ImageDefault' }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server' // Gen2
        version: 'latest'
      }
      osDisk: {
        name: 'osdisk-${prefix}'
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
        deleteOption: 'Delete'
      }
      dataDisks: [
        {
          // cloud-init finds LUN 0 (/dev/disk/azure/data/by-lun/0 or scsi1/lun0) and mounts it at /var/lib/docker.
          name: 'datadisk-${prefix}-docker'
          lun: 0
          createOption: 'Empty'
          diskSizeGB: dataDiskSizeGB
          managedDisk: { storageAccountType: 'StandardSSD_LRS' }
          caching: 'ReadOnly'
          deleteOption: 'Detach'
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [ { id: nic!.id } ]
    }
    diagnosticsProfile: {
      bootDiagnostics: { enabled: true } // managed storage, no extra account
    }
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Cool'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    // Only Entra ID auth; SAS tokens are user-delegation SAS minted with `az ... --as-user`.
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: 7 }
    containerDeleteRetentionPolicy: { enabled: true, days: 7 }
  }
}

resource backupsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'backups'
  properties: { publicAccess: 'None' }
}

resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'expire-old-backups'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: { blobTypes: [ 'blockBlob' ], prefixMatch: [ 'backups/' ] }
            actions: {
              baseBlob: { delete: { daysAfterModificationGreaterThan: backupRetentionDays } }
            }
          }
        }
      ]
    }
  }
}

// Storage Blob Data Contributor, so the operator can create user-delegation SAS tokens.
var blobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
resource backupOperatorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(backupOperatorPrincipalId)) {
  name: guid(storage.id, backupOperatorPrincipalId, blobDataContributorRoleId)
  scope: storage
  properties: {
    principalId: backupOperatorPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataContributorRoleId)
  }
}

// The VM may write to the backups container only (not the whole account).
resource vmBackupRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployVm) {
  name: guid(backupsContainer.id, vmName, blobDataContributorRoleId)
  scope: backupsContainer
  properties: {
    principalId: vm!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataContributorRoleId)
  }
}

output vmName string = deployVm ? vmName : ''
output publicIp string = deployVm ? pip!.properties.ipAddress : ''
output sshCommand string = deployVm ? 'ssh -i ~/.ssh/imagine_demo ${adminUsername}@${pip!.properties.ipAddress}' : ''
output storageAccountName string = storage.name
output backupsContainerUrl string = '${storage.properties.primaryEndpoints.blob}backups'
output nsgName string = nsg.name
