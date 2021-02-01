param(
    [Parameter(Mandatory=$true)]$ResourceGroup,
    [Parameter(Mandatory=$true)]$Workspace,    
    [Parameter(Mandatory=$true)]$Location
)


function CheckModules($module) {
    $service = Get-Module -ListAvailable -Name $module
    if (-Not $service) {        
        Write-Host "Module does not exist"
        Install-Module -Name $module -Scope CurrentUser -Force
    }    
}

CheckModules("Az.Resources")
CheckModules("Az.OperationalInsights")
CheckModules("Az.SecurityInsights")

Write-Host "`r`nIf not logged in to Azure already, you will now be asked to log in to your Azure environment. `nFor this script to work correctly, you need to provide credentials of a Global Admin or Security Admin for your organization. `nThis will allow the script to enable all required connectors.`r`n" -BackgroundColor Magenta

Read-Host -Prompt "Press enter to continue or CTRL+C to quit the script" 

$context = Get-AzContext

if(!$context){
    Connect-AzAccount
    $context = Get-AzContext
}

$SubscriptionId = $context.Subscription.Id

$ConnectorsFile = "$PSScriptRoot\connectors.json"
#Create Resource Group
Get-AzResourceGroup -Name $ResourceGroup -ErrorVariable notPresent -ErrorAction SilentlyContinue

if ($notPresent){
    Write-Host "Creating resource group $ResourceGroup in region $Location..."
    New-AzResourceGroup -Name $ResourceGroup -Location $Location
}
else{
    Write-Host "Resource Group $ResourceGroup already exists. Skipping..."
}

#Create Log Analytics workspace
try {

    $WorkspaceObject = Get-AzOperationalInsightsWorkspace -Name $Workspace -ResourceGroupName $ResourceGroup  -ErrorAction Stop
    $ExistingLocation = $WorkspaceObject.Location
    Write-Output "Workspace named $Workspace in region $ExistingLocation already exists. Skipping..."

} catch {

    Write-Output "Creating new workspace named $Workspace in region $Location..."
    # Create the new workspace for the given name, region, and resource group
    New-AzOperationalInsightsWorkspace -Location $Location -Name $Workspace -Sku Standard -ResourceGroupName $ResourceGroup

}

$solutions = Get-AzOperationalInsightsIntelligencePack -resourcegroupname $ResourceGroup -WorkspaceName $Workspace -WarningAction:SilentlyContinue

if (($solutions | Where-Object Name -eq 'SecurityInsights').Enabled) {
    Write-Host "Azure Sentinel is already installed on workspace $($Workspace)"
}
else {
    Set-AzSentinel -WorkspaceName $Workspace -Confirm:$false
}

$msTemplates = Get-AzSentinelAlertRuleTemplate -WorkspaceName $Workspace -ResourceGroupName $ResourceGroup | where Kind -EQ MicrosoftSecurityIncidentCreation

#Resource URL to authentincate against
$Resource = "https://management.azure.com/"

#Urls to be used for Sentinel API calls
$baseUri = "/subscriptions/${SubscriptionId}/resourceGroups/${ResourceGroup}/providers/Microsoft.OperationalInsights/workspaces/${Workspace}"
$connectedDataConnectorsUri = "$baseUri/providers/Microsoft.SecurityInsights/dataConnectors/?api-version=2020-01-01"

function Get-ConnectedDataconnectors{
    try {
            $allConnectedDataconnectors = (Invoke-AzRestMethod -Path $connectedDataConnectorsUri -Method GET).Content | ConvertFrom-Json			
        }
    catch {
        $errorReturn = $_
        Write-Error "Unable to invoke webrequest with error message: $errorReturn" -ErrorAction Stop
    }
    return $allConnectedDataconnectors
}

function checkDataConnector($dataConnector){
    $currentDataconnector = "" | Select-Object -Property guid,etag,isEnabled
    if ($allConnectedDataconnectors.value.Length -ne 0){
        foreach ($value in $allConnectedDataconnectors.value){			
            if ($value.kind -eq $dataConnector) {
                Write-Host "Successfully queried data connector $($value.kind) - already enabled"
                Write-Verbose $value
                
                $currentDataconnector.guid = $value.name
                $currentDataconnector.etag = $value.etag
                $currentDataconnector.isEnabled = $true
                break					
            }
        }
        if ($currentDataconnector.isEnabled -ne $true)
        {
            $currentDataconnector.guid = (New-Guid).Guid
            $currentDataconnector.etag = $null
            $currentDataconnector.isEnabled = $false
        }
    }
    else{        
        $currentDataconnector.guid = (New-Guid).Guid
        $currentDataconnector.etag = $null
        $currentDataconnector.isEnabled = $false
    }
    return $currentDataconnector
}

function BuildDataconnectorPayload($dataConnector, $guid, $etag, $isEnabled){    
    if ($dataConnector.kind -ne "AzureSecurityCenter")
    {
        $connectorProperties = $dataConnector.properties
        $connectorProperties | Add-Member -NotePropertyName tenantId -NotePropertyValue ${context}.Tenant.Id
    }
    else {
        $connectorProperties = $dataConnector.properties
        $connectorProperties | Add-Member -NotePropertyName subscriptionId -NotePropertyValue ${context}.Subscription.Id
    }	
    
    if ($isEnabled) {
		# Compose body for connector update scenario
		Write-Host "Updating data connector $($dataConnector.kind)"
		Write-Verbose "Name: $guid"
		Write-Verbose "Etag: $etag"
		
		$connectorBody = @{}

		$connectorBody | Add-Member -NotePropertyName kind -NotePropertyValue $dataConnector.kind -Force
		$connectorBody | Add-Member -NotePropertyName name -NotePropertyValue $guid -Force
		$connectorBody | Add-Member -NotePropertyName etag -NotePropertyValue $etag -Force
		$connectorBody | Add-Member -NotePropertyName properties -NotePropertyValue $connectorProperties
	}
	else {
		# Compose body for connector enable scenario
		Write-Host "$($dataConnector.kind) data connector is not enabled yet"
		Write-Host "Enabling data connector $($dataConnector.kind)"
        Write-Verbose "Name: $guid"
        
		$connectorBody = @{}

		$connectorBody | Add-Member -NotePropertyName kind -NotePropertyValue $dataConnector.kind -Force
		$connectorBody | Add-Member -NotePropertyName properties -NotePropertyValue $connectorProperties

	}
	return $connectorBody
}

function EnableOrUpdateDataconnector($baseUri, $guid, $connectorBody, $isEnabled){ 
	$uri = "${baseUri}/providers/Microsoft.SecurityInsights/dataConnectors/${guid}?api-version=2020-01-01"
	try {
		$result = Invoke-AzRestMethod -Path $uri -Method PUT -Payload ($connectorBody | ConvertTo-Json -Depth 3)
		if ($result.StatusCode -eq 200) {
			if ($isEnabled){
				Write-Host "Successfully updated data connector: $($connector.kind)" -ForegroundColor Green
			}
			else {
				Write-Host "Successfully enabled data connector: $($connector.kind)" -ForegroundColor Green
			}
		}
		else {
			Write-Error "Unable to enable data connector $($connector.kind) with error: $($result.Content)" 
		}
		Write-Host ($body.Properties | Format-List | Format-Table | Out-String)
	}
	catch {
		$errorReturn = $_
		Write-Verbose $_
		Write-Error "Unable to invoke webrequest with error message: $errorReturn" -ErrorAction Stop
	}
}

function EnableMSAnalyticsRule($msProduct){ 
    try {
        foreach ($rule in $msTemplates){
            if ($rule.productFilter -eq $msProduct) {
                New-AzSentinelAlertRule -ResourceGroupName $ResourceGroup -WorkspaceName $Workspace -DisplayName $rule.displayName -MicrosoftSecurityIncidentCreation -Description $rule.description -ProductFilter $msProduct                
                Write-Host "Done!" -ForegroundColor Green
            }
        }
	}
	catch {
		$errorReturn = $_
		Write-Verbose $_
		Write-Error "Unable to create analytics rule with error message: $errorReturn" -ErrorAction Stop
	}
}

#Getting all rules from file
$connectors = Get-Content -Raw -Path $ConnectorsFile | ConvertFrom-Json

#Getting all connected Data connectors
$allConnectedDataconnectors = Get-ConnectedDataconnectors


foreach ($connector in $connectors.connectors) {
    Write-Host "`r`nProcessing connector: " -NoNewline 
    Write-Host "$($connector.kind)" -ForegroundColor Blue

    #AzureActivityLog connector
    if ($connector.kind -eq "AzureActivityLog") {
        $SubNoHyphens = $SubscriptionId -replace '-',''
        $uri = "$baseUri/datasources/${SubNoHyphens}?api-version=2015-11-01-preview"
        $connectorBody = ""
        $activityEnabled = $false

        #Check if AzureActivityLog is already connected (there is no better way yet) [assuming there is only one AzureActivityLog from same subscription connected]
        try {
            # AzureActivityLog is already connected, compose body with existing etag for update
            $result = Invoke-AzRestMethod -Path $uri -Method GET
            if ($result.StatusCode -eq 200){
                Write-Host "Successfully queried data connector ${connector.kind} - already enabled"
                Write-Verbose $result
                Write-Host "Updating data connector $($connector.kind)"

                $activityEnabled = $true
            }
            else {
                Write-Host "$($connector.kind) data connector is not enabled yet"
                Write-Host "Enabling data connector $($connector.kind)"
                $activityEnabled = $false
            }
        }
        catch { 
            $errorReturn = $_
            Write-Error "Unable to invoke webrequest with error message: $errorReturn" -ErrorAction Stop
        }

        $connectorProperties = @{
            linkedResourceId = "/subscriptions/${SubscriptionId}/providers/microsoft.insights/eventtypes/management"
        }        
                
        $connectorBody = @{}

        $connectorBody | Add-Member -NotePropertyName kind -NotePropertyValue $connector.kind -Force
        $connectorBody | Add-Member -NotePropertyName properties -NotePropertyValue $connectorProperties

        #Enable or Update AzureActivityLog Connector with http puth method
        try {
            $result = Invoke-AzRestMethod -Path $uri -Method PUT -Payload ($connectorBody | ConvertTo-Json -Depth 3)
            if ($result.StatusCode -eq 200) {
                if ($activityEnabled){
                    Write-Host "Successfully updated data connector: $($connector.kind)" -ForegroundColor Green
                }
                else {
                    Write-Host "Successfully enabled data connector: $($connector.kind)" -ForegroundColor Green 
                } 
            }
            else {
                Write-Host "Unable to enable data connector $($connector.kind) with error: $($result.Content)" 
            }   
            Write-Verbose ($body.Properties | Format-List | Format-Table | Out-String)
        }
        catch {
            $errorReturn = $_
            Write-Verbose $_.Exception.Message
            Write-Error "Unable to invoke webrequest with error message: $errorReturn" -ErrorAction Stop
        }  
    }

    #AzureSecurityCenter connector
    elseif ($connector.kind -eq "AzureSecurityCenter") {  
        $dataConnectorBody = ""        
        #query for connected Data connectors
        $connectorProperties = checkDataConnector($connector.kind)
        $dataConnectorBody = BuildDataconnectorPayload $connector $connectorProperties.guid $connectorProperties.etag $connectorProperties.isEnabled
        EnableOrUpdateDataconnector $baseUri $connectorProperties.guid $dataConnectorBody $connectorProperties.isEnabled
        Write-Host "Adding Analytics Rule for data connector Azure Security Center..." -NoNewline
        EnableMSAnalyticsRule "Azure Security Center" 
    }
    #Office365 connector
    elseif ($connector.kind -eq "Office365") {
        $dataConnectorBody = ""        
        #query for connected Data connectors
        $connectorProperties = checkDataConnector($connector.kind)
        $dataConnectorBody = BuildDataconnectorPayload $connector $connectorProperties.guid $connectorProperties.etag $connectorProperties.isEnabled
        EnableOrUpdateDataconnector $baseUri $connectorProperties.guid $dataConnectorBody $connectorProperties.isEnabled
    }
    #MicrosoftCloudAppSecurity connector
    elseif ($connector.kind -eq "MicrosoftCloudAppSecurity") {
        $dataConnectorBody = ""        
        #query for connected Data connectors
        $connectorProperties = checkDataConnector($connector.kind)
        $dataConnectorBody = BuildDataconnectorPayload $connector $connectorProperties.guid $connectorProperties.etag $connectorProperties.isEnabled
        EnableOrUpdateDataconnector $baseUri $connectorProperties.guid $dataConnectorBody $connectorProperties.isEnabled
        Write-Host "Adding Analytics Rule for data connector Microsoft Cloud App Security..." -NoNewline
        EnableMSAnalyticsRule "Microsoft Cloud App Security" 
    }
    #AzureAdvancedThreatProtection connector
    elseif ($connector.kind -eq "AzureAdvancedThreatProtection") {
        $dataConnectorBody = ""        
        #query for connected Data connectors
        $connectorProperties = checkDataConnector($connector.kind)
        $dataConnectorBody = BuildDataconnectorPayload $connector $connectorProperties.guid $connectorProperties.etag $connectorProperties.isEnabled
        EnableOrUpdateDataconnector $baseUri $connectorProperties.guid $dataConnectorBody $connectorProperties.isEnabled
        Write-Host "Adding Analytics Rule for data connector Azure Advanced Threat Protection..." -NoNewline
        EnableMSAnalyticsRule "Azure Advanced Threat Protection" 
    }
    #ThreatIntelligencePlatforms connector
    elseif ($connector.kind -eq "ThreatIntelligence") {
        $dataConnectorBody = ""        
        #query for connected Data connectors
        $connectorProperties = checkDataConnector($connector.kind)
        $dataConnectorBody = BuildDataconnectorPayload $connector $connectorProperties.guid $connectorProperties.etag $connectorProperties.isEnabled
        EnableOrUpdateDataconnector $baseUri $connectorProperties.guid $dataConnectorBody $connectorProperties.isEnabled
    }
    #MicrosoftDefenderAdvancedThreatProtection connector
    elseif ($connector.kind -eq "MicrosoftDefenderAdvancedThreatProtection") {
        $dataConnectorBody = ""        
        #query for connected Data connectors
        $connectorProperties = checkDataConnector($connector.kind)
        $dataConnectorBody = BuildDataconnectorPayload $connector $connectorProperties.guid $connectorProperties.etag $connectorProperties.isEnabled
        EnableOrUpdateDataconnector $baseUri $connectorProperties.guid $dataConnectorBody $connectorProperties.isEnabled
        Write-Host "Adding Analytics Rule for data connector Microsoft Defender Advanced Threat Protection..." -NoNewline
        EnableMSAnalyticsRule "Microsoft Defender Advanced Threat Protection" 
    }
    #Azure Active Directory Identity Protection connector
    elseif ($connector.kind -eq "AzureActiveDirectory") {
        $dataConnectorBody = ""        
        #query for connected Data connectors
        $connectorProperties = checkDataConnector($connector.kind)
        $dataConnectorBody = BuildDataconnectorPayload $connector $connectorProperties.guid $connectorProperties.etag $connectorProperties.isEnabled
        EnableOrUpdateDataconnector $baseUri $connectorProperties.guid $dataConnectorBody $connectorProperties.isEnabled
        Write-Host "Adding Analytics Rule for data connector Azure Active Directory Identity Protection..." -NoNewline
        EnableMSAnalyticsRule "Azure Active Directory Identity Protection" 
    }
    #AzureActiveDirectory
    elseif ($connector.kind -eq "AzureActiveDirectoryDiagnostics") {
        <# Azure Active Directory Audit/SignIn logs - requires special call and is therefore not connectors file
        # Be aware that you executing SPN needs Owner rights on tenant scope for this operation, can be added with following CLI
        # az role assignment create --role Owner --scope "/" --assignee {13ece749-d0a0-46cf-8000-b2552b520631}#>
        $uri = "/providers/microsoft.aadiam/diagnosticSettings/AzureSentinel_${Workspace}?api-version=2017-04-01"
           
        $connectorProperties = $connector.properties
        $connectorProperties | Add-Member -NotePropertyName workspaceId -NotePropertyValue "/subscriptions/${SubscriptionId}/resourcegroups/${ResourceGroup}/providers/Microsoft.OperationalInsights/workspaces/${Workspace}"

        $connectorBody = @{}

        $connectorBody | Add-Member -NotePropertyName name -NotePropertyValue "AzureSentinel_${Workspace}"
        $connectorBody.Add("properties",$connectorProperties)
        
               
        try {
            $result = Invoke-AzRestMethod -Path $uri -Method PUT -Payload ($connectorBody | ConvertTo-Json -Depth 3)
            if ($result.StatusCode -eq 200) {
                Write-Host "Successfully enabled data connector: $($connector.kind)" -ForegroundColor Green
            }
            else {
                Write-Error "Unable to enable data connector $($connector.kind) with error: $($result.Content)" 
            }
            Write-Verbose ($body.Properties | Format-List | Format-Table | Out-String)
        }
        catch {
            $errorReturn = $_
            Write-Verbose $_
            Write-Error "Unable to invoke webrequest with error message: $errorReturn" -ErrorAction Stop
        }
    }
        
    
}