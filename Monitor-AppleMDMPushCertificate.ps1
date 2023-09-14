<#
    .SYNOPSIS
        Monitor Apple MDM push certificate in Intune, send email notification when expired or close to expiry.

    .DESCRIPTION
        This script is deployed via a Bicep deployment script in the form of an Azure PowerShell 7.2 Runbook under an Automation Account, running on a recurring schedule.
        The Automation Account requires a system assigned managed identity. The identity requires 'DeviceManagementServiceConfig.Read.All' and 'Mail.Send' permissions to the tenant's Microsoft Graph API.
        It first initialises the connection to Microsoft Graph with the system assigned managed identity.
        The script calls the Microsoft Graph API and retrieves the Apple MDM push certificate resource from Intune. It then validates the certificate expiry date.
        If certificate is expired or is within the specified timespan, it will then call the Graph API to send an email notifying the specified recipient.

    .NOTES
        AUTHOR: Christopher Cooper
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

####----------------[FUNCTIONS]----------------####

# Dynamically set mail parameters
function Set-MailParams {
    param (
        [Parameter(Mandatory)]
        [ValidateSet('MDMPushCertificate', 'ABMToken', 'VPPToken')]
        [string]$Type,
        [Parameter(Mandatory)]
        [ValidateSet('True', 'False')]
        [string]$Expired,
        [Parameter]
        [ValidateSet([int])]
        [int]$DaysLeft,
        [Parameter(Mandatory)]
        [string]$ClientName
    )
    ## Variables for mail subject and body for type of cert/token ##
    switch ($Type) {
        'MDMPushCertificate' {
            $mailType = 'Apple MDM Push certificate'
            $mailDocumentationURL = 'https://learn.microsoft.com/en-us/mem/intune/enrollment/apple-mdm-push-certificate-get#renew-apple-mdm-push-certificate'            
        }
        'ABMToken' {
            $mailType = 'Apple Business Manager enrollment token'
            $mailDocumentationURL = ''          
        }
        'VPPToken' {
            $mailType = 'Apple Volume Purchase Program (VPP) token'
            $mailDocumentationURL = ''       
        }
    }
    ## Variables for mail subject and body for expiry state ##
    if ($Expired -eq 'True') {
        $mailSubjectExpiryState = ' has expired - '
        $mailBodyExpiryState = " has expired, for client '"
    }
    else {
        $mailSubjectExpiryState = " expires in $($DaysLeft) days - "
        $mailBodyExpiryState = " expires in $($DaysLeft)  days, for client '"
    }
    ## Combine mail subject and body variables ##
    $mailSubject = 'Microsoft Intune: IMPORTANT - ' + $mailType + $mailSubjectExpiryState + $ClientName
    $mailBody = $mailType + $mailBodyExpiryState + $ClientName + "'. Please renew as per documentation:" + $mailDocumentationURL
    ## Set mail parameters to mail subject and body variables ##
    $mailParams.message.subject = $mailSubject
    $mailParams.message.body.content = $mailBody
    $mailParams.message.torecipients.emailaddress.address = $mailTo
}

# Get expiration date of either Apple MDM push certificate, or Apple Business Manager enrollment token
function Get-IntuneAppleCertAndTokensExpiry {
    param (
        [Parameter(Mandatory)]
        [ValidateSet('MDMPushCertificate', 'ABMToken', 'VPPToken')]
        [string]$Type
    )
    ## Depending on parameter input ##
    switch ($Type) {
        'MDMPushCertificate' {
            # Apple MDM push certificate Graph URL
            $graphUri = 'https://graph.microsoft.com/v1.0/devicemanagement/applePushNotificationCertificate'
            # Get current Apple MDM Push certificate
            $graphResource = Invoke-MgGraphRequest -Uri $graphUri -Method GET
            if ($graphResource) {
                Write-Output 'Successfully retrieved Apple MDM Push certificate'
            }
            else {
                Write-Output 'Query for Apple MDM Push certificate returned empty'
            }
            $expirationDate = [System.DateTime]::Parse($graphResource.expirationDateTime) 
        }
        'ABMToken' {    
            # Apple Business Manager enrollment token Graph URL
            $graphUri = 'https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings'
            # Get current Apple Business Manager enrollment token
            $graphResource = Invoke-MgGraphRequest -Uri $graphUri -Method GET
            if ($graphResource) {
                Write-Output 'Successfully retrieved Apple Business Manager enrollment token'
            }
            else {
                Write-Output 'Query for Apple Business Manager enrollment token returned empty'
            }
            # Parse the JSON date time string into a DateTime object
            # This needs to be ParseExact in form of MM/dd/yyy - When parsing it as is, it is interpreted as MM/dd/yyyy
            $expirationDate = [System.DateTime]::ParseExact($graphResource.Value.tokenExpirationDateTime, 'MM/dd/yyyy HH:mm:ss', $null)
        }
        'VPPToken' {
            # Apple Volume Purchase Program (VPP) token Graph URL
            $graphUri = 'https://graph.microsoft.com/v1.0/deviceAppManagement/vppTokens'
            # Get current VPP token
            $graphResource = Invoke-MgGraphRequest -Uri $graphUri -Method GET
            if ($graphResource) {
                Write-Output 'Successfully retrieved Apple Volume Purchase Program (VPP) token'
            }
            else {
                Write-Output 'Query for Apple Volume Purchase Program (VPP) token returned empty'
            }
            # Parse the JSON date time string into a DateTime object
            # This needs to be ParseExact in form of MM/dd/yyy - When parsing it as is, it is interpreted as MM/dd/yyyy
            $expirationDate = [System.DateTime]::ParseExact($graphResource.Value.ExpirationDateTime, 'MM/dd/yyyy HH:mm:ss', $null)
        }
    }
    return $expirationDate
}

####----------------[SCRIPT]----------------####

Write-Output 'Running automation...'
## Connect to MS Graph with system-assigned managed identity ##
Write-Output 'Connecting to MS Graph with system-assigned managed identity'
$mgGraphConnection = Connect-MgGraph -Identity
if ($mgGraphConnection) {
    Write-Output 'Successfully connected to MS Graph'
    ## Check current Apple MDM Push certificate ##
    $appleMDMPushCertExpiry = New-Timespan -Start (Get-Date) -End (Get-IntuneAppleCertAndTokensExpiry -Type MDMPushCertificate)
    switch ($appleMDMPushCertExpiry) {
        # If expiry is within specified notification timespan
        {$_.Days -le $notificationTimespan} {
            Write-Output 'Apple MDM Push certificate has not expired, but is within the specified expiration notification timespan, sending notification email'
            # Send email notification
            Set-MailParams -Type MDMPushCertificate -Expired False -ClientName $clientName
            Send-MgUserMail -UserId $mailFrom -BodyParameter $mailParams
        }
        # If expired
        {$_.Days -le 0} {
            Write-Output 'Apple MDM Push certificate is expired, sending notification email'
            # Send email notification                
            Set-MailParams -Type MDMPushCertificate -Expired True -DaysLeft $appleMDMPushCertExpiry.Days -ClientName $clientName
            Send-MgUserMail -UserId $mailFrom -BodyParameter $mailParams
        }
        # If not expired nor within specified notification timespan
        default {
            Write-Output 'Apple MDM Push certificate has not expired and is outside of the specified expiration notification timespan'
        }
    }
    ## Check current Apple Business Manager enrollment token ##
    $abmTokenExpiry = New-Timespan -Start (Get-Date) -End (Get-IntuneAppleCertAndTokensExpiry -Type ABMToken)
    switch ($abmTokenExpiry) {
        # If expiry is within specified notification timespan
        {$_.Days -le $notificationTimespan} {
            Write-Output 'Apple Business Manager enrollment token has not expired, but is within the specified expiration notification timespan, sending notification email'
            # Send email notification
            Set-MailParams -Type ABMToken -Expired False -ClientName $clientName
            Send-MgUserMail -UserId $mailFrom -BodyParameter $mailParams
        }
        # If expired
        {$_.Days -le 0} {
            Write-Output 'Apple Business Manager enrollment token is expired, sending notification email'
            # Send email notification                
            Set-MailParams -Type ABMToken -Expired True -DaysLeft $abmTokenExpiry.Days -ClientName $clientName
            Send-MgUserMail -UserId $mailFrom -BodyParameter $mailParams
        }
        # If not expired nor within specified notification timespan
        default {
            Write-Output 'Apple Business Manager enrollment token has not expired and is outside of the specified expiration notification timespan'
        }
    }
    ## Check current Volume Purchase Program (VPP) token ##
    $vppTokenExpiry = New-Timespan -Start (Get-Date) -End (Get-IntuneAppleCertAndTokensExpiry -Type VPPToken)
    switch ($vppTokenExpiry) {
        # If expiry is within specified notification timespan
        {$_.Days -le $notificationTimespan} {
            Write-Output 'Apple Volume Purchase Program (VPP) token has not expired, but is within the specified expiration notification timespan, sending notification email'
            # Send email notification
            Set-MailParams -Type VPPToken -Expired False -ClientName $clientName
            Send-MgUserMail -UserId $mailFrom -BodyParameter $mailParams
        }
        # If expired
        {$_.Days -le 0} {
            Write-Output 'Apple Volume Purchase Program (VPP) token is expired, sending notification email'
            # Send email notification                
            Set-MailParams -Type VPPToken -Expired True -DaysLeft $vppTokenExpiry.Days -ClientName $clientName
            Send-MgUserMail -UserId $mailFrom -BodyParameter $mailParams
        }
        # If not expired nor within specified notification timespan
        default {
            Write-Output 'Apple Volume Purchase Program (VPP) token has not expired and is outside of the specified expiration notification timespan'
        }
    }
}
else {
    Write-Warning 'Failed to connect to MS Graph'
}















    


#    # Get Apple MDM push certificate expiry
#    if ($Type -eq 'Certificate') {
#        # Apple MDM push certificate Graph URL
#        $graphUri = 'https://graph.microsoft.com/v1.0/devicemanagement/applePushNotificationCertificate'
#        # Get current Apple MDM Push certificate
#        $graphResource = Invoke-MgGraphRequest -Uri $graphUri -Method GET
#        if ($graphResource) {
#            Write-Output 'Successfully retrieved Apple MDM Push certificate'
#        }
#        else {
#            Write-Output 'Query for Apple MDM Push certificate returned empty'
#        }
#        # Parse the JSON date time string into a DateTime object
#        $expirationDate = [System.DateTime]::Parse($graphResource.expirationDateTime)
#    }
#    # Get Apple Business Manager enrollment token expiry
#    else {
#        # Apple Business Manager enrollment token Graph URL
#        $graphUri = 'https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings'
#        # Get current Apple Business Manager enrollment token
#        $graphResource = Invoke-MgGraphRequest -Uri $graphUri -Method GET
#        if ($graphResource) {
#            Write-Output 'Successfully retrieved Apple Business Manager enrollment token'
#        }
#        else {
#            Write-Output 'Query for Apple Business Manager enrollment token returned empty'
#        }
#        # Parse the JSON date time string into a DateTime object
#        # This needs to be ParseExact in form of MM/dd/yyy - Despite it appearing in the same form as the cert's date in Graph, when parsing it as is it thinks it is MM/dd/yyyy
#        $expirationDate = [System.DateTime]::ParseExact($graphResource.Value.tokenExpirationDateTime, 'MM/dd/yyyy HH:mm:ss', $null)
#    }
#    # Return expiration date of cert or token
##    return $expirationDate
##}
#
#Write-Output 'Running automation...'
## Connect to MS Graph with system-assigned managed identity
#Write-Output 'Connecting to MS Graph with system-assigned managed identity'
#$mgGraphConnection = Connect-MgGraph -Identity
#if ($mgGraphConnection) {
#    Write-Output 'Successfully connected to MS Graph'
#    ## Get current Apple MDM Push certificate ##
#    $appleMDMPushCertificateExpirationDate = Get-AppleMDMPushCertOrABMTokenExpirationDate -Type Certificate
#    # If Apple MDM Push certificate is expired
#    if ($appleMDMPushCertificateExpirationDate -lt (Get-Date)) {
#        Write-Output 'Apple MDM Push certificate has already expired, sending notification email'
#        # Send email notification                
#        $mailSubject = 'MSIntune: IMPORTANT - Apple MDM Push certificate has expired - ' + $clientName
#        $mailBody = 'Apple MDM Push certificate has expired, for client ' + $clientName + '. Please renew certificate as per documentation: https://learn.microsoft.com/en-us/mem/intune/enrollment/apple-mdm-push-certificate-get#renew-apple-mdm-push-certificate'
#        Set-MailParams
#        Send-MgUserMail -UserId $mailFrom -BodyParameter $mailParams
#    }
#    else {
#        # Get timespan on Apple MDM Push certificate expiry
#        $appleMDMPushCertificateDaysLeft = ($appleMDMPushCertificateExpirationDate - (Get-Date))
#        # If Apple MDM Push certificate expiry is within specified notification timespan
#        if ($appleMDMPushCertificateDaysLeft.Days -le $notificationTimespan) {
#            Write-Output 'Apple MDM Push certificate has not expired, but is within the specified expiration notification timespan'
#            # Send email notification
#            $mailSubject = 'MSIntune: Apple MDM Push certificate expires in $($AppleMDMPushCertificateDaysLeft.Days) days - ' + $clientName
#            $mailBody = 'Apple MDM Push certificate expires in ' + $($AppleMDMPushCertificateDaysLeft.Days) + ' days, for client ' + $clientName + '. Please renew certificate as per documentation: https://learn.microsoft.com/en-us/mem/intune/enrollment/apple-mdm-push-certificate-get#renew-apple-mdm-push-certificate'
#            Set-MailParams
#            Send-MgUserMail -UserId $mailFrom -BodyParameter $mailParams
#        }
#        else {
#            Write-Output 'Apple MDM Push certificate has not expired and is outside of the specified expiration notification timespan'
#        }
#    }
#    ## Get current Apple Business Manager enrollment token ##
#    $abmTokenExpirationDate = Get-AppleMDMPushCertOrABMTokenExpirationDate -Type Token
#    # If Apple Business Manager enrollment token is expired
#    if ($abmTokenExpirationDate -lt (Get-Date)) {
#        Write-Output 'Apple MDM Push certificate has already expired, sending notification email'
#        # Send Email notification                   
#        $mailSubject = 'MSIntune: IMPORTANT - Apple MDM Push certificate has expired - ' + $clientName
#        $mailBody = 'Apple MDM Push certificate has expired, for client ' + $clientName + '. Please renew certificate as per documentation: https://learn.microsoft.com/en-us/mem/intune/enrollment/apple-mdm-push-certificate-get#renew-apple-mdm-push-certificate'
#        Set-MailParams
#        Send-MgUserMail -UserId $mailFrom -BodyParameter $mailParams
#    }
#    else {
#        # Get timespan on MDM Push Certificate expiry
#        $abmTokenExpirationDate = ($abmTokenExpirationDate - (Get-Date))
#        if ($abmTokenExpirationDate.Days -le $notificationTimespan) {
#            Write-Output 'Apple MDM Push certificate has not expired, but is within the specified expiration notification timespan'
#            # Send email notification
#            $mailSubject = 'MSIntune: Apple MDM Push certificate expires in $($abmTokenExpirationDate.Days) days - ' + $clientName
#            $mailBody = 'Apple MDM Push certificate expires in ' + $($abmTokenExpirationDate.Days) + ' days, for client ' + $clientName + '. Please renew certificate as per documentation: https://learn.microsoft.com/en-us/mem/intune/enrollment/apple-mdm-push-certificate-get#renew-apple-mdm-push-certificate'
#            Set-MailParams
#            Send-MgUserMail -UserId $mailFrom -BodyParameter $mailParams
#        }
#        else {
#            Write-Output 'Apple MDM Push certificate has not expired and is outside of the specified expiration notification timespan'
#        }
#    }
#}
#else {
#    Write-Output 'An error occurred while attempting to connect to MS Graph'
#}

### OLD CODE TO REFACTOR ###

#try {
## Connect to MS Graph with system-assigned managed identity
#    Write-Output 'Connecting to MS Graph with system-assigned managed identity'
#    $mgGraphConnection = Connect-MgGraph -Identity
#    if ($mgGraphConnection) {
#        Write-Output 'Successfully connected to MS Graph'
#        try {
#            # Get current Apple MDM Push certificate
#            $appleMDMPushCertificateExpirationDate = Get-AppleMDMPushCertOrABMTokenExpirationDate -Type Certificate
#            if ($appleMDMPushCertificateExpirationDate) {
#                Write-Output 'Successfully retrieved Apple MDM Push certificate expiration date'
#                # Validate that the MDM Push certificate has not already expired
#                if ($appleMDMPushCertificateExpirationDate -lt (Get-Date)) {
#                    Write-Output 'Apple MDM Push certificate has already expired, sending notification email'                   
#                    $mailSubject = 'MSIntune: IMPORTANT - Apple MDM Push certificate has expired - ' + $clientName
#                    $mailBody = 'Apple MDM Push certificate has expired, for client ' + $clientName + '. Please renew certificate as per documentation: https://learn.microsoft.com/en-us/mem/intune/enrollment/apple-mdm-push-certificate-get#renew-apple-mdm-push-certificate'
#                    Set-MailParams
#                    Send-MgUserMail -UserId $mailFrom -BodyParameter $mailParams
#                }
#                else {
#                    # Get timespan on MDM Push Certificate expiry
#                    $appleMDMPushCertificateDaysLeft = ($appleMDMPushCertificateExpirationDate - (Get-Date))
#                    if ($appleMDMPushCertificateDaysLeft.Days -le $notificationTimespan) {
#                        Write-Output 'Apple MDM Push certificate has not expired, but is within the given expiration notification timespan'
#                        $mailSubject = 'MSIntune: Apple MDM Push certificate expires in $($AppleMDMPushCertificateDaysLeft.Days) days - ' + $clientName
#                        $mailBody = 'Apple MDM Push certificate expires in ' + $($AppleMDMPushCertificateDaysLeft.Days) + ' days, for client ' + $clientName + '. Please renew certificate as per documentation: https://learn.microsoft.com/en-us/mem/intune/enrollment/apple-mdm-push-certificate-get#renew-apple-mdm-push-certificate'
#                        Set-MailParams
#                        Send-MgUserMail -UserId $mailFrom -BodyParameter $mailParams
#                    }
#                    else {
#                        Write-Output 'Apple MDM Push certificate has not expired and is outside of the specified expiration notification timespan'
#                    }
#                }
#            }
#            else {
#                Write-Output 'Query for Apple MDM Push certificate expiration date returned empty'
#            }    
#        }
#        catch [System.Exception] {
#            Write-Warning -Message 'An error occurred. Error message: $($_.Exception.Message)'
#        }
#    }
#    else {
#        Write-Warning -Message 'An error occurred while attempting to connect to MS Graph'
#    }
#}
#catch [System.Exception] {
#    Write-Warning -Message 'Failed to connect to MS Graph'
#}
