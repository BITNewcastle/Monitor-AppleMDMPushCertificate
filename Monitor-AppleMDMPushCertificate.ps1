<#
    .SYNOPSIS
        Monitor Apple MDM push certificate in Intune, send email notification when expired or close to expiry.

    .DESCRIPTION
        This script is deployed in the form of an Azure PowerShell 7.2 Runbook under an Automation Account, running on a recurring schedule.
        The Automation Account requires a system assigned managed identity. The identity requires 'DeviceManagementServiceConfig.Read.All' and 'Mail.Send' permissions to the tenant's Microsoft Graph API.
        It first initialises the connection to Microsoft Graph with the system assigned managed identity.
        The script calls the Microsoft Graph API and retrieves the Apple MDM push certificate resource from Intune. It then validates the certificate expiry date.
        If certificate is expired or is within the specified timespan, it will then call the Graph API to send an email notifying the specified recipient.

    .NOTES
        AUTHOR: Originally Nickolaj Andersen, revised by Christopher Cooper
        This script has been revised and adapted to suit.
        https://github.com/MSEndpointMgr/Intune/blob/master/Automation/Get-AppleMDMPushCertificateExpiration.ps1
#>


#-------------------[INITIALISATIONS]-------------------#

# Define input parameters
param (
    # Expiration notification timespan i.e. notify when cert expires in x days
    [parameter(Mandatory=$false)]  
    [int]$notificationTimespan,
    # Expiration notification email parameters
    [parameter(Mandatory=$false)]  
    [string]$mailFrom,
    [parameter(Mandatory=$false)]  
    [string]$mailTo,
    [parameter(Mandatory=$false)]  
    [string]$clientName
)
# Define parameters for expiration notification email
$mailParams = @{
    Message = @{
        Subject = $mailSubject
        Body = @{
            ContentType = 'Text'
            Content = $mailBody
        }
        ToRecipients = @(
            @{
                EmailAddress = @{
                    Address = $mailTo
                }
            }
        )
    }
    SaveToSentItems = 'true'
}
# Define function to dynamically set mail parameters
function Set-MailParams {
    $mailParams.message.subject = $mailSubject
    $mailParams.message.body.content = $mailBody
    $mailParams.message.torecipients.emailaddress.address = $mailTo
}


####----------------[SCRIPT]----------------####

try {
    # Connect to MS Graph with system-assigned managed identity
    Write-Output -InputObject 'Connecting to MS Graph with system-assigned managed identity'
    $msGraphConnection = Connect-MgGraph -Identity
    if ($null -ne $msGraphConnection) {
        Write-Output -InputObject 'Successfully connected to MS Graph'
        try {
            # Get current Apple MDM Push certificate
            $appleMDMPushResource = 'https://graph.microsoft.com/v1.0/devicemanagement/applePushNotificationCertificate'
            $appleMDMPushCertificate = Invoke-MgGraphRequest -Uri $appleMDMPushResource -Method GET
            if ($null -ne $AppleMDMPushCertificate) {
                Write-Output -InputObject 'Successfully retrieved Apple MDM Push certificate'
                # Parse the JSON date time string into an DateTime object
                $appleMDMPushCertificateExpirationDate = [System.DateTime]::Parse($appleMDMPushCertificate.expirationDateTime)

                # Validate that the MDM Push certificate has not already expired
                if ($appleMDMPushCertificateExpirationDate -lt (Get-Date)) {
                    Write-Output -InputObject 'Apple MDM Push certificate has already expired, sending notification email'                   
                    $mailSubject = 'MSIntune: IMPORTANT - Apple MDM Push certificate has expired - ' + $clientName
                    $mailBody = 'Apple MDM Push certificate has expired, for client ' + $clientName + '. Please renew certificate as per documentation: https://learn.microsoft.com/en-us/mem/intune/enrollment/apple-mdm-push-certificate-get#renew-apple-mdm-push-certificate'
                    Set-MailParams
                    Send-MgUserMail -UserId $mailFrom -BodyParameter $mailParams
                }
                else {
                    # Get timespan on MDM Push Certificate expiry
                    $appleMDMPushCertificateDaysLeft = ($appleMDMPushCertificateExpirationDate - (Get-Date))
                    if ($appleMDMPushCertificateDaysLeft.Days -le $notificationTimespan) {
                        Write-Output -InputObject 'Apple MDM Push certificate has not expired, but is within the given expiration notification timespan'
                        $mailSubject = 'MSIntune: Apple MDM Push certificate expires in $($AppleMDMPushCertificateDaysLeft.Days) days - ' + $clientName
                        $mailBody = 'Apple MDM Push certificate expires in ' + $($AppleMDMPushCertificateDaysLeft.Days) + ' days, for client ' + $clientName + '. Please renew certificate as per documentation: https://learn.microsoft.com/en-us/mem/intune/enrollment/apple-mdm-push-certificate-get#renew-apple-mdm-push-certificate'
                        Set-MailParams
                        Send-MgUserMail -UserId $mailFrom -BodyParameter $mailParams
                    }
                    else {
                        Write-Output -InputObject 'Apple MDM Push certificate has not expired and is outside of the specified expiration notification timespan'
                    }
                }
            }
            else {
                Write-Output -InputObject 'Query for Apple MDM Push certificates returned empty'
            }    
        }
        catch [System.Exception] {
            Write-Warning -Message 'An error occurred. Error message: $($_.Exception.Message)'
        }
    }
    else {
        Write-Warning -Message 'An error occurred while attempting to connect to MS Graph'
    }
}
catch [System.Exception] {
    Write-Warning -Message 'Failed to connect to MS Graph'
}