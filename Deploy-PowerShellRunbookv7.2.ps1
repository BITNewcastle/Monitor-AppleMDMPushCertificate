<#
    .SYNOPSIS
        Deploys PowerShell 7.1 Runbook under an existing Automation Account.

    .DESCRIPTION
        This script is deployed in the form of a deployment script, as part of a Bicep deployment.
        Import PowerShell module dependency to existing automation account first, before proceeding with rest of script.
        Imports remaining PowerShell module to existing automation account.
        Creates draft PowerShell 7.1 runbook.
        Uploads specified PS script content to runbook.
        Publishes runbook.
        Deletes the user-assigned managed identity and role assigment associated with this deployment script - cleans up.

    .NOTES
        AUTHOR: Christopher Cooper
#>


#-------------------[INITIALISATIONS]-------------------#

# Input parameters to be passed from Bicep deployment
param (
    [string]$resourceGroupName, 
    [string]$automationAccountName,
    [string]$runbookName,
    [string]$location,
    [string]$runbookScriptUri,
    [string]$managedIdentityUserAssignedName
)

# Outputs to allow for nested template
$DeploymentScriptOutputs = @{}
$DeploymentScriptOutputs['runbookName'] = $runbookName


####----------------[SCRIPT]----------------####

## Import PowerShell module dependency to existing automation account
function New-AzAutomationPS7ModuleDependency {
    param (
        [string]$ResourceGroupName, 
        [string]$AutomationAccountName,
        [string]$ModuleName,
        [string]$ModuleVersion
    )  
    # Import module
    Write-Output "Importing module ${ModuleName}"
    Invoke-AzRestMethod -Method 'PUT' `
        -ResourceGroupName $ResourceGroupName -ResourceProviderName 'Microsoft.Automation' `
        -ResourceType 'automationAccounts' -Name "$AutomationAccountName/powershell7Modules/$ModuleName" -ApiVersion 2022-08-08 `
        -Payload "{`"properties`":{`"contentLink`":{`"uri`":`'https://www.powershellgallery.com/api/v2/package/$ModuleName/$ModuleVersion`'}}}"
    # Wait until module is imported
    do {
        $Result = Invoke-AzRestMethod -Method 'GET' `
                    -ResourceGroupName $ResourceGroupName -ResourceProviderName 'Microsoft.Automation' `
                    -ResourceType 'automationAccounts' -Name "$AutomationAccountName/powershell7Modules/$ModuleName" -ApiVersion 2022-08-08 `
                    -Payload "{`'properties`':{`'contentLink`':{`'uri`':`'https://www.powershellgallery.com/api/v2/package/$ModuleName/$ModuleVersion`'}}}"
        $ProvisioningState = (($Result.Content | ConvertFrom-Json).Properties).provisioningState
        Start-Sleep -Seconds 15
        if ($ProvisioningState -eq 'Failed') {
            Write-Output "Import of module ${ModuleName} failed"
            break
        }
    } until ($ProvisioningState -eq 'Succeeded')       
}

## Import remaining PowerShell module to existing automation account
function New-AzAutomationPS7Module {
    param (
        [string]$ResourceGroupName, 
        [string]$AutomationAccountName,
        [string]$ModuleName,
        [string]$ModuleVersion
    )
    # Import module
    Write-Output "Importing module ${ModuleName}"
    Invoke-AzRestMethod -Method 'PUT' `
        -ResourceGroupName $ResourceGroupName -ResourceProviderName 'Microsoft.Automation' `
        -ResourceType 'automationAccounts' -Name "$AutomationAccountName/powershell7Modules/$ModuleName" -ApiVersion 2022-08-08 `
        -Payload "{`'properties`':{`'contentLink`':{`'uri`':`'https://www.powershellgallery.com/api/v2/package/$ModuleName/$ModuleVersion`'}}}"
}

## Create PowerShell 7 runbook, upload script content and publish runbook ##
function New-AzAutomationPS7Runbook {
    param (
        [string]$ResourceGroupName, 
        [string]$AutomationAccountName,
        [string]$Location,
        [string]$RunbookScriptUri
    )
    # Get content of PS script
    $ScriptContent = Invoke-RestMethod $RunbookScriptUri
    # Create PowerShell 7 runbook
    Write-Output "Creating PowerShell 7 runbook ${RunbookName}"
    Invoke-AzRestMethod -Method 'PUT' `
        -ResourceGroupName $ResourceGroupName -ResourceProviderName 'Microsoft.Automation' `
        -ResourceType 'automationAccounts' -Name "$AutomationAccountName/runbooks/$RunbookName" -ApiVersion 2022-08-08 `
        -Payload "{`'properties`':{`'runbookType`':`'PowerShell7`', `'logProgress`':false, `'logVerbose`':false, `'draft`':{}}, `'location`':`'${Location}`'}"
    # Upload PS script to runbook
    Write-Output "Uploading ${RunbookScriptUri} to ${RunbookName}"
    Invoke-AzRestMethod -Method 'PUT' `
        -ResourceGroupName $ResourceGroupName -ResourceProviderName 'Microsoft.Automation' `
        -ResourceType 'automationAccounts' -Name "$AutomationAccountName/runbooks/$RunbookName/draft/content" -ApiVersion 2022-08-08 `
        -Payload $ScriptContent
    # Publish runbook
    Write-Output "Publishing runbook ${RunbookName}"
    Publish-AzAutomationRunbook -Name $RunbookName -AutomationAccountName $AutomationAccountName -ResourceGroupName $ResourceGroupName
}

## Deletes the user-assigned managed identity and role assigment associated with this deployment script - cleans up
function Remove-ManagedIdentityResources {
    param (
        [string]$ManagedIdentityUserAssignedName
    )
    # Remove role assignment
    Write-Output "Removing role assignment from ${ManagedIdentityUserAssignedName}"
    $ManagedIdentityUserAssignedPrincipalId = (Get-AzADServicePrincipal -DisplayName $ManagedIdentityUserAssignedName).Id
    Get-AzRoleAssignment -ObjectId $ManagedIdentityUserAssignedPrincipalId | Remove-AzRoleAssignment
    # Delete user-assigned managed identity
    Write-Output "Deleting ${ManagedIdentityUserAssignedName}"
    Remove-AzUserAssignedIdentity -ResourceGroupName $ResourceGroupName -Name $ManagedIdentityUserAssignedName
}


# Call functions
New-AzAutomationPS7ModuleDependency -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName -ModuleName 'Microsoft.Graph.Authentication' -ModuleVersion '1.28.0'
New-AzAutomationPS7Module -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName -ModuleName 'Microsoft.Graph.Users.Actions' -ModuleVersion '1.28.0'
New-AzAutomationPS7Runbook -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName -Location $location -RunbookScriptUri $runbookScriptUri
Remove-ManagedIdentityResources -ManagedIdentityUserAssignedName $managedIdentityUserAssignedName
