<#
    .SYNOPSIS
        Deploys Azure PowerShell 7.2 Runbook under an existing Automation Account.

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
  [string]$location,
  [string]$scriptURI
)

# Get content of PS script
$scriptContent = Invoke-RestMethod $scriptURI


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
