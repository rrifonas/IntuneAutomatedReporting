﻿<#

.COPYRIGHT
Copyright (c) Microsoft Corporation. All rights reserved. Licensed under the MIT license.
See LICENSE in the project root for license information.

#>

####################################################

# Variables
$subscriptionID = Get-AutomationVariable 'subscriptionID' # Azure Subscription ID Variable
$tenantID = Get-AutomationVariable 'tenantID' # Azure Tenant ID Variable
$resourceGroupName = Get-AutomationVariable 'resourceGroupName' # Resource group name
$storageAccountName = Get-AutomationVariable 'storageAccountName' # Storage account name

# Report specific Variables
$containerName = Get-AutomationVariable 'installedapps' # Resource group name
#$containerSnapshotName = Get-AutomationVariable 'installedappssnapshot' # Storage account name

# Graph App Registration Creds

# Uses a Secret Credential named 'GraphApi' in your Automation Account
$clientInfo = Get-AutomationPSCredential 'GraphApi'
# Username of Automation Credential is the Graph App Registration client ID 
$clientID = $clientInfo.UserName
# Password  of Automation Credential is the Graph App Registration secret key (create one if needed)
$secretPass = $clientInfo.GetNetworkCredential().Password

#Required credentials - Get the client_id and client_secret from the app when creating it in Azure AD
$client_id = $clientID #App ID
$client_secret = $secretPass #API Access Key Password

####################################################

function Get-AuthToken {

<#
.SYNOPSIS
This function is used to authenticate with the Graph API REST interface
.DESCRIPTION
The function authenticate with the Graph API Interface with the tenant name
.EXAMPLE
Get-AuthToken
Authenticates you with the Graph API interface
.NOTES
NAME: Get-AuthToken
#>

    param
    (
        [Parameter(Mandatory=$true)]
        $TenantID,
        [Parameter(Mandatory=$true)]
        $ClientID,
        [Parameter(Mandatory=$true)]
        $ClientSecret
    )
               
    try{
        # Define parameters for Microsoft Graph access token retrieval
        $resource = "https://graph.microsoft.com"
        $authority = "https://login.microsoftonline.com/$TenantID"
        $tokenEndpointUri = "$authority/oauth2/token"
               
        # Get the access token using grant type client_credentials for Application Permissions
        $content = "grant_type=client_credentials&client_id=$ClientID&client_secret=$ClientSecret&resource=$resource"
        $response = Invoke-RestMethod -Uri $tokenEndpointUri -Body $content -Method Post -UseBasicParsing -Verbose:$false

        Write-Host "Got new Access Token!" -ForegroundColor Green
        Write-Host

        # If the accesstoken is valid then create the authentication header
        if($response.access_token){
               
            # Creating header for Authorization token
               
            $authHeader = @{
                'Content-Type'='application/json'
                'Authorization'="Bearer " + $response.access_token
                'ExpiresOn'=$response.expires_on
            }
               
            return $authHeader
               
        }
        else{    
            Write-Error "Authorization Access Token is null, check that the client_id and client_secret is correct..."
            break    
        }
    }
    catch{    
        FatalWebError -Exeption $_.Exception -Function "Get-AuthToken"   
    }

}

####################################################

Function Get-ValidToken {

<#
    .SYNOPSIS
    This function is used to identify a possible existing Auth Token, and renew it using Get-AuthToken, if it's expired
    .DESCRIPTION
    Retreives any existing Auth Token in the session, and checks for expiration. If Expired, it will run the Get-AuthToken Fucntion to retreive a new valid Auth Token.
    .EXAMPLE
    Get-ValidToken
    Authenticates you with the Graph API interface by reusing a valid token if available - else a new one is requested using Get-AuthToken
    .NOTES
    NAME: Get-ValidToken
#>

    #Fixing client_secret illegal char (+), which do't go well with web requests
    $client_secret = $($client_secret).Replace("+","%2B")
               
    # Checking if authToken exists before running authentication
    if($global:authToken){
               
        # Get current time in (UTC) UNIX format (and ditch the milliseconds)
        $CurrentTimeUnix = $((get-date ([DateTime]::UtcNow) -UFormat +%s)).split((Get-Culture).NumberFormat.NumberDecimalSeparator)[0]
                              
        # If the authToken exists checking when it expires (converted to minutes for readability in output)
        $TokenExpires = [MATH]::floor(([int]$authToken.ExpiresOn - [int]$CurrentTimeUnix) / 60)
               
        if($TokenExpires -le 0){    
            Write-Host "Authentication Token expired" $TokenExpires "minutes ago! - Requesting new one..." -ForegroundColor Green
            $global:authToken = Get-AuthToken -TenantID $tenantID -ClientID $client_id -ClientSecret $client_secret    
        }
        else{
            Write-Host "Using valid Authentication Token that expires in" $TokenExpires "minutes..." -ForegroundColor Green
            #Write-Host
        }
    }    
    # Authentication doesn't exist, calling Get-AuthToken function    
    else {       
        # Getting the authorization token
        $global:authToken = Get-AuthToken -TenantID $tenantID -ClientID $client_id -ClientSecret $client_secret    
    }    
}

####################################################

Function Get-IntuneAppInventory(){

<#
.SYNOPSIS
This function is used to get applications from the Graph API REST interface
.DESCRIPTION
The function connects to the Graph API Interface and gets any applications added
.EXAMPLE
Get-IntuneApplication
Returns any applications configured in Intune
.NOTES
NAME: Get-IntuneAppInventory
#>

[cmdletbinding()]

param
(
    [parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$type
)

$graphApiVersion = "Beta"
$Resource = "deviceManagement/reports/exportJobs"

    try {

        $uri = "https://graph.microsoft.com/$graphApiVersion/$($Resource)"

       $JSON = @"
{
    "reportName": "$type",
    "filter": "",
    "select": [
        "ApplicationKey",
        "ApplicationName",
        "ApplicationPublisher",
        "ApplicationVersion",
        "DeviceId",
        "DeviceName",
        "OSDescription",
        "OSVersion",
        "Platform",
        "UserId",
        "EmailAddress",
        "UserName"
    ],
    "localization": "true",
    "ColumnName": "ui"
}
"@

      Invoke-RestMethod -Uri $uri -Headers $authToken -Method Post -Body $JSON -ContentType "application/json"
       

    }

    catch {

    $ex = $_.Exception
    Write-Host "Request to $Uri failed with HTTP Status $([int]$ex.Response.StatusCode) $($ex.Response.StatusDescription)" -f Red
    $errorResponse = $ex.Response.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($errorResponse)
    $reader.BaseStream.Position = 0
    $reader.DiscardBufferedData()
    $responseBody = $reader.ReadToEnd();
    Write-Host "Response content:`n$responseBody" -f Red
    Write-Error "Request to $Uri failed with HTTP Status $($ex.Response.StatusCode) $($ex.Response.StatusDescription)"
    write-host
    break

    }

}

####################################################

Function Get-ReportStatus(){

<#
.SYNOPSIS
This function is used to get applications from the Graph API REST interface
.DESCRIPTION
The function connects to the Graph API Interface and gets any applications added
.EXAMPLE
Get-IntuneApplication
Returns any applications configured in Intune
.NOTES
NAME: Get-IntuneAppReportStatus
#>

[cmdletbinding()]

param
(
    [Parameter(Mandatory=$true)]
    [string] $reportId
)

$graphApiVersion = "Beta"
$Resource = "deviceManagement/reports/exportJobs"

    try {

        $uri = "https://graph.microsoft.com/$graphApiVersion/$($Resource)('$reportId')" 

      Invoke-RestMethod -Uri $uri -Headers $authToken -Method Get
       

    }

    catch {

    $ex = $_.Exception
    Write-Host "Request to $Uri failed with HTTP Status $([int]$ex.Response.StatusCode) $($ex.Response.StatusDescription)" -f Red
    $errorResponse = $ex.Response.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($errorResponse)
    $reader.BaseStream.Position = 0
    $reader.DiscardBufferedData()
    $responseBody = $reader.ReadToEnd();
    Write-Host "Response content:`n$responseBody" -f Red
    Write-Error "Request to $Uri failed with HTTP Status $($ex.Response.StatusCode) $($ex.Response.StatusDescription)"
    write-host
    break

    }

}

####################################################


#region Authentication

# Checking if authToken exists before running authentication
if($global:authToken){

    # Setting DateTime to Universal time to work in all timezones
    $DateTime = (Get-Date).ToUniversalTime()

    # If the authToken exists checking when it expires
    $TokenExpires = ($authToken.ExpiresOn.datetime - $DateTime).Minutes

    if($TokenExpires -le 0){

        Write-Output ("Authentication Token expired" + $TokenExpires + "minutes ago")

        #Calling Microsoft to see if they will give us access with the parameters defined in the config section of this script.
        Get-ValidToken

        $global:authToken = Get-AuthToken -TenantID $tenantID -ClientID $client_id -ClientSecret $client_secret
    }
}

# Authentication doesn't exist, calling Get-AuthToken function

else {

    #Calling Microsoft to see if they will give us access with the parameters defined in the config section of this script.
    Get-ValidToken

    # Getting the authorization token
    $global:authToken = Get-AuthToken -TenantID $tenantID -ClientID $client_id -ClientSecret $client_secret
}

#endregion

####################################################

$report = Get-IntuneAppInventory -type "AppInvRawData"

Write-Host "Running report..." -f Cyan

$reportid = $report.id
$reportstatus = $report.status

# wait for report to complete
while ($reportstatus -ine "completed") {
    $getreport = Get-ReportStatus -reportId $reportid

    $getreportstatus = $getreport.status
    
    Write-Host "In progress..." -f Yellow

    $reportstatus = $getreportstatus

    Start-Sleep -Seconds 5

}

Write-Host "Success!" -f Green

$url = $getreport.url

$outputfolder = ".\report.zip"

# download zip folder
Invoke-WebRequest -Uri $url -OutFile $outputfolder

# unzip
Expand-Archive -LiteralPath ".\report.zip" -DestinationPath ".\myreport"

# Rename file.csv
$csv = Get-ChildItem '.\myreport\*.csv' | Select-Object -ExpandProperty Name
Rename-Item -Path ".\myreport\$csv" -NewName "AppInvRawData.csv"


# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process
try
{
    Write-Output ("Logging in to Azure...")
    Connect-AzAccount -Identity
}
catch {
    Write-Error -Message $_.Exception
    throw $_.Exception
}

Select-AzSubscription -SubscriptionId $subscriptionID

Set-AzCurrentStorageAccount -StorageAccountName $storageAccountName -ResourceGroupName $resourceGroupName

Set-AzStorageBlobContent -Container $ContainerName -File .\myreport\AppInvRawData.csv -Blob AppInvRawData.csv -Force

#Add snapshot file with timestamp
#$date = Get-Date -format "dd-MMM-yyyy_HH:mm"
#$timeStampFileName = "AppInvRawData.csv_" + $date + ".csv"
#Set-AzStorageBlobContent -Container $containerSnapshotName -File '.\myreport\AppInvRawData.csv' -Blob $timeStampFileName -Force 
