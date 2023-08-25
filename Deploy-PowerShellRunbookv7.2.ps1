<#
    .SYNOPSIS
        Deploys Azure PowerShell 7.2 Runbook under an Automation Account, and sets the required Microsoft Graph API permissions.

    .DESCRIPTION
        

    .NOTES
        AUTHOR: Christopher Cooper
#>


#-------------------[INITIALISATIONS]-------------------#

# Define input parameters
param(
  [string]$resourceGroupName, 
  [string]$automationAccountName,
  [string]$runbookName,
  [string]$location
)

#$resourceGroupName = 'test-applemdmcert_monitoring'
#$automationAccountName = 'test-applemdmcert-monitoring'
#$runbookName = 'test-applemdmcert-monitoring7.2'
#$location = 'australiaeast'

# Define PS script to be uploaded to runbook
$scriptURL = 'https://cdn.jsdelivr.net/gh/BITNewcastle/Monitor-AppleMDMPushCertificate/Monitor-AppleMDMPushCertificate.ps1'
$scriptContent = Invoke-RestMethod $scriptURL
# Define variables for MS Graph API permissions #
$resourceAppId = '00000003-0000-0000-c000-000000000000' # MS Graph application
$permissionList = 'DeviceManagementServiceConfig.Read.All', 'Mail.Send' # Read MS Intune service properties, and send mail as user


####----------------[SCRIPT]----------------####

## Create PowerShell 7.2 runbook, upload script content and publish runbook ##
# Create PowerShell 7.2 runbook 
Invoke-AzRestMethod -Method "PUT" -ResourceGroupName $resourceGroupName -ResourceProviderName "Microsoft.Automation" `
        -ResourceType "automationAccounts" -Name "${automationAccountName}/runbooks/${runbookName}" -ApiVersion  2022-06-30-preview `
        -Payload "{`"properties`":{`"runbookType`":`"PowerShell`", `"runtime`":`"PowerShell-7.2`", `"logProgress`":false, `"logVerbose`":false, `"draft`":{}}, `"location`":`"$($location)`"}"
# Upload PS script to runbook
Invoke-AzRestMethod -Method "PUT" -ResourceGroupName $resourceGroupName -ResourceProviderName "Microsoft.Automation" `
        -ResourceType "automationAccounts" -Name "${automationAccountName}/runbooks/${runbookName}/draft/content" -ApiVersion 2015-10-31 `
        -Payload "$scriptContent"
# Publish runbook
Publish-AzAutomationRunbook -Name $runbookName -AutomationAccountName $automationAccountName -ResourceGroupName $resourceGroupName

## Set required MS Graph API permissions for the automation account ##
$MSI = (Get-AzADServicePrincipal -Filter "displayName eq '$automationAccountName'")
if (!$MSI) { throw "Automation account '$automationAccountName' doesn't exist" }
$resourceSP = Get-AzADServicePrincipal -Filter "appId eq '$resourceAppId'"
if (!$resourceSP) { throw "Resource '$resourceAppId' doesn't exist" }
foreach ($permission in $permissionList) {
    $appRole = $resourceSP.AppRoles | Where-Object { $_.Value -eq $permission -and $_.AllowedMemberTypes -contains "Application" }
    if (!$appRole) {
        Write-Warning "Application permission '$permission' wasn't found in '$resourceAppId' application. Therefore it cannot be added."
        continue
    }
    New-AzureADServiceAppRoleAssignment -ObjectId $MSI.ObjectId -PrincipalId $MSI.ObjectId -ResourceId $resourceSP.ObjectId -Id $appRole.Id
}
