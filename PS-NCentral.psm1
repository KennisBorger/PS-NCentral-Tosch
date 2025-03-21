## PowerShell Module for N-Central(c) by N-Able
##
## Version	:	1.7
## Author	:	Adriaan Sluis (a.sluis@kennisborging.nl)
##
## !Still some Work In Progress!
##
## Provides a PowerShell Interface for N-Central(c)
## Uses the SOAP-API of N-Central(c) by N-Able
## Completely written in PowerShell for easy reference/analysis.
##

##Copyright 2024 Kennisborging.nl
##
##Licensed under the Apache License, Version 2.0 (the "License");
##you may not use this file except in compliance with the License.
##You may obtain a copy of the License at
##
##    http://www.apache.org/licenses/LICENSE-2.0
##
##Unless required by applicable law or agreed to in writing, software
##distributed under the License is distributed on an "AS IS" BASIS,
##WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
##See the License for the specific language governing permissions and
##limitations under the License.
##

## Change log
##
## v1.2		Feb 24, 2021
## -Made PowerShell 7 compatible by removing usage of WebServiceProxy.
## -Sorting CustomProperty-columns by default (NoSort/UnSorted Option available)
## -JWT-option in New-NCentralConnection
##
## v1.3		Mar 23, 2022
## -CustomProperty 	- Get individual Property Values. (Was list-only)
## -CustomProperty 	- Add/Remove individual (Comma-separated) values inside the CP.
## -CustomProperty 	- Optional Base64 Encoding/Decoding.
## -CustomerDetails	- ValidationList for standard-/custom-property filled by API-query.
## -Enhanced Get-NCAccessGroupList/Detail
## -Enhanced Get-NCUserRoleList/Detail
##
## v1.4		May 20,2022
## -(issue) NCActiveIssueList -Status 1 and 5 were swapped. -Added NotifStateTxt-field
## -(issue) NCDeviceInfo - Multiple-values now shown comma-separated (was only showing first entry)
## -NCDeviceObject - Options to Include/Exclude categories
## -Optimized API-calls for multiple objects where supported (NCDeviceInfo and NCCDeviceObject)
## -ShowProgress option for NCDeviceInfo and NCDeviceObject using optimized API-calls.
## -Date/Time properties now have date-format (was String)
## -NCHelp shows a list of statuscodes at the bottom. (.NCStatus)
##
## v1.5		june 29, 2022
## -(issue) NCDevicePropertyList and NCCustomerPropertylist - Error on property-names containing spaces.
## -Optimized API-calls for multiple objects where supported (NCDevicePropertyList and NCCustomerPropertylist added)
## -NCCustomerPropertylist - Full-option to include basic properties
## -Backup-NCCustomProperties - Backup of All CustomerProperties and Custom Device-Properties of associated devices.
##
## v1.6		TBD
## -(issue) Get-NCCustomerList - Renew-option to rebuild cache.
## -(issue) Get-Help <CmdLet> -detailed - Not showing Parameter Helpmessage
## -UserAdd function added to Class (No CmdLet yet)
## -CustomerAdd function enhanced
## -Default CustomerID autoupdate for Hosted NCentral.
## -ShowProgress option for NCDevicePropertyList using optimized API-calls or Filters.
## -Check URL-structure before connecting.
##
## v1.7		TBD
## -Introduction of REST-API, in parallel to SOAP.
## -Use of REST-API by default. (Fallback to SOAP)
## -Select-NCCustomerUI function for Selecting a Customer from a List
## -Select-NCDeviceUI function for Selecting a Customer-Device from a List
##
##
## v2.0		TBD
## -CP -Backup/Restore to/from JSON v2
##

#Region Classes and Generic Functions
using namespace System.Net

Class NCentral_Connection {
## Using the Interface ServerEI2_PortType for SOAP
## See documentation @:https://nfr.n-able.com/dms/javadoc_ei2/com/nable/nobj/ei2/ServerEI2_PortType.html
## Documentation on REST-API @: https://nfr.n-able.com/api-explorer


#Region Properties

	## TODO - Enum-lists for ErrorIDs, ...
	## TODO - Cleanup WebProxy code (whole module)

	## Initialize the API-specific values (as static).
	## No separate NameSpace needed because of Class-enclosure. Instance NameSpace available as Property.
	#static hidden [String]$NWSNameSpace = "NCentral" + ([guid]::NewGuid()).ToString().Substring(25)
	#static hidden [String]$SoapURLBase = "/dms2/services2/ServerEI2?wsdl"	## for WebserviceProxy
	static hidden [String]$SoapURLBase = "/dms2/services2/ServerEI2"		## 
	static hidden [String]$RestURLBase = "/api"
	
	## Create Properties
	[String]$PSNCVersion = "1.7"			## The PS-NCentral version
	[String]$ConnectionURL					## Server FQDN
	[String]$SoapURL						## Full SOAP-path
	[String]$RestURL						## Base REST-path
	[Boolean]$ForceSOAP = $false			## Option to use SOAP-requests only
	hidden [PSCredential]$Creds = $null		## Encrypted Credentials
	hidden [Hashtable]$MyHeaders			## REST-header including Authentication
	hidden [Datetime]$TokenExpiration		## REST-access-token expiry
	#Hidden [Object]$Mysession				## Might be an alternative for $MyHeaders/$Creds. Not preferred security-wise.

	#[String]$AllProtocols = 'tls12,tls13'	## Https encryption	--> issue on older systems, not supporting 1.3
	[String]$AllProtocols = @(If (([System.Net.SecurityProtocolType]).DeclaredMembers.Name -contains "Tls13") { 'tls12,tls13' } Else { 'tls12' }) ## Https encryption - minimum Tls 1.2 needed
	[int]$RequestTimeOut = 100				## Default timeout in Seconds
	[Int16]$PageMaxSize =100				## UpperLimit REST page-size
	#hidden [Object]$NameSpace				## For accessing API-Class Objects (WebServiceProxy). Deprecated from version 1.2.
	#hidden [Object]$ConnectedVersion		## For storing full VersionInfoGet-data. Changed to Method 'NCVersionRequest'.
	[Boolean]$IsConnected = $false			## Connection Status
	[Boolean]$IsHosted = $false				## Hosted N-Central indicator (Info from NCVersionRequest)
	[String]$NCVersion						## The UI-version of the connected server (Info from Host)
	[int]$DefaultCustomerID					## Used when no CustomerID is supplied in most device-commands
	[Object]$Error							## Last known Error

	## Create a general Key/Value Pair. Will be casted at use. Skipped in most methods for non-reuseablity.
	## Integrated (available in session only): $KeyPair = New-Object -TypeName ($NameSpace + '.tKeyPair')
	#hidden $KeyPair = [PSObject]@{Key=''; Value='';}

	## Create Key/Value Pairs container(Array).
	hidden [Array]$KeyPairs = @()

	## Defaults and ValidationLists
	hidden [Array]$rc									#Returned Raw Collection of NCentral-Data.
	hidden [Boolean]$CustomerDataModified = $false		#Customer-Cache rebuild flag
	hidden [Collections.ArrayList]$RequestFilter = @()	#Hold categories to Limit/Filter AssetDetails

	## Validation/Lookup-lists
	hidden [Collections.IDictionary]$NCStatus=@{}		#Status Code/Description. Initiated/filled in the constructor.
	hidden [Array]$UserValidation = @()					#Supports UserAddition. Initiated/filled in the constructor.
	hidden [Object]$CustomerData						#Caching of CustomerData for quick reference. Filled at connect.
	hidden [Array]$CustomerValidation = @()				#Supports decision between Customer- and Organization-properties. Filled dynamically at connect.

	## Work In Progress
	#$tCreds

	## Testing / Debugging only
	hidden $Testvar
#	$this.Testvar = $this.GetType().name

#EndRegion Properties
	
#Region Constructors

	#Base Constructors
	## Using ConstructorHelper for chaining.
	
	NCentral_Connection(){
	
		Try{
			## [ValidatePattern('^server\d{1,4}$')]
			$ServerFQDN = Read-Host "Enter the fqdn of the N-Central Server"
		}
		Catch{
			Write-Host "Connection Aborted"
			Break
		}
		$PSCreds = Get-Credential -Message "Enter NCentral API-User credentials"
		$this.ConstructorHelper($ServerFQDN,$PSCreds)
	}
	
	NCentral_Connection([String]$ServerFQDN){
		$PSCreds = Get-Credential -Message "Enter NCentral API-User credentials"
		$this.ConstructorHelper($ServerFQDN,$PSCreds)
	}
	
	NCentral_Connection([String]$ServerFQDN,[String]$JWT){
		$SecJWT = (ConvertTo-SecureString $JWT -AsPlainText -Force)
		$PSCreds = New-Object PSCredential ("_JWT", $SecJWT)
		$this.ConstructorHelper($ServerFQDN,$PSCreds)
	}

	NCentral_Connection([String]$ServerFQDN,[PSCredential]$PSCreds){
		$this.ConstructorHelper($ServerFQDN,$PSCreds)
	}

	hidden ConstructorHelper([String]$ServerFQDN,[PSCredential]$Credentials){
		## Constructor Chaining not Standard in PowerShell. Needs a Helper-Method.
		##
		## ToDo: 	ValidatePattern for $ServerFQDN
			
		If (!$ServerFQDN){	
			Write-Host "Invalid ServerFQDN given."
			Break
		}
		If (!$Credentials){	
			Write-Host "No Credentials given."
			Break
		}

		## Construct Session-parameters.
		## Place in Class-Property for later reference.
		$this.ConnectionURL = $ServerFQDN		
		$this.Creds = $Credentials

		#Write-Debug "Connecting to $this.ConnectionURL."
		
		## Remove prefix if given
		If ($this.ConnectionURL.Contains("://")){
			$this.ConnectionURL = $this.ConnectionURL.Split("://")[1]
		}
		$this.SoapURL = ("https://{0}{1}" -f $this.ConnectionURL, [NCentral_Connection]::SoapURLBase)
		$this.RestURL = ("https://{0}{1}" -f $this.ConnectionURL, [NCentral_Connection]::RestURLBase)

		
		## Remove existing/previous default-instance. Clears previous login.
		If($null -ne $Global:_NCSession){
			Remove-Variable _NCSession -scope global
		}

		## Initiate the session to the NCentral-server.
		$this.Connect()

		## Fill Reference/Lookup-lists

		## NCStatus - correct spelling essential for ActiveIssuesList filtering.
		$this.NCStatus.1	= "No Data"
		$this.NCStatus.2	= "Stale"
		$this.NCStatus.3	= "Normal"        ## --> Nothing returned in ActiveIssuesList
		$this.NCStatus.4	= "Warning"
		$this.NCStatus.5	= "Failed"
		$this.NCStatus.6	= "Misconfigured"
		$this.NCStatus.7	= "Disconnected"
		$this.NCStatus.8	= "Disabled"
		$this.NCStatus.11 = "Unacknowledged"
		$this.NCStatus.12 = "Acknowledged"

		## Supports UserAddition
		$this.UserValidation = @("customerID",
							"email",
							"password",
							"firstname",
							"lastname",
							"username",
							"country",
							"zip/postalcode",
							"street1",
							"street2",
							"city",
							"state/province",
							"telephone",
							"ext",
							"department",
							"notificationemail",
							"status",
							"userroleID",
							"accessgroupID",
							"apionlyuser"
						)
	}	
	

#EndRegion Constructors

#Region Methods
#	## Features
#	## Returns all data as Object-collections to allow pipelines.
#	## Mimic the names of the API-method/URL where possible.
#	## Supports Synchronous Requests only (for now).
#	## NO 'Dangerous' API's are implemented (Delete/Remove).
#	## 	
#	## To Do
#	## TODO - Check for $this.IsConnected before execution.
#	## TODO - General Error-handling + customized throws.
#	## TODO - Additional Add/Set-methods
#	## TODO - Progress indicator (Write-Progress) - Not all commands yet
#	## TODO - Error on AccessGroupGet
#	## TODO - Async processing
#	##

	#Region ClassSupport

	#Region Support - Connection
    ## Connection Support
	[void]Connect(){
	
		## Reset connection-indicator
		$this.IsConnected = $false

		## Secure communications
		[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}		## Seems indifferent for N-Central communication.
		[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]$this.AllProtocols

		## Extract NCental UI version from returned data
		$this.NCVersion = ($this.NCVersionRequest() | 
							Where-Object {$_.key -eq "Installation: Deployment Product Version"} ).value

		## Is this hosted N-Central
		$Hosted = $($this.NCVersionRequest() | 
							Where-Object {$_.key -eq 'N-able Hosted Platform'} ).value
		If($Hosted -eq "NCOD"){
			$this.IsHosted = $true
		}

		## TODO Make valid check on connection-error (incl. Try/Catch)
		## Now checking on succesful version-data retrieval.
		if ($this.NCVersion){
			$this.IsConnected = $true
		}

		## Fill cache-settings and validation-lists.

		## CustomerList-cache is filled.		--> moved to Get-NCCustomerList
		#$this.CustomerData = $this.customerlist()

		## Store names of standard customer-properties. For differentiating from COPs.
		# CustomerAdd/Modify fields put in front for template exports.
		$this.CustomerValidation = @("customerid","customername","parentid") + 
									($this.customerlist($true) | get-member -MemberType NoteProperty ).name |
									Select-Object -Unique
	}

	hidden [String]PlainUser(){
		$CredUser = $this.Creds.GetNetworkCredential().UserName

		If ($CredUser -eq '_JWT'){
			Return $null
		}
		Else{
			Return $CredUser
		}
	}
	
	hidden [String]PlainPass(){
		Return $this.Creds.GetNetworkCredential().Password
	}

	[void]ErrorHandler(){
		$this.ErrorHandler($this.Error)
	}

	[void]ErrorHandler($ErrorObject){
	
		#Write-Host$ErrorObject.Exception|Format-List -Force
		#Write-Host ($ErrorObject.Exception.GetType().FullName)
#		$global:ErrObj = $ErrorObject


#		Write-Host ($ErrorObject.Exception.Message)
		Write-Host ($ErrorObject.ErrorDetails.Message)
		
#		Known Errors List:
#		Connection-error (https): There was an error downloading ..
#	    1012 - Thrown when mandatory settings are not present in "settings".
#	    2001 - Required parameter is null - Thrown when null values are entered as inputs.
#	    2001 - Unsupported version - Thrown when a version not specified above is entered as input.
#	    2001 - Thrown when a bad username-password combination is input, or no PSA integration has been set up.
#	    2100 - Thrown when invalid MSP N-central credentials are input.
#	    2100 - Thrown when MSP-N-central credentials with MFA are used.
#	    3010 - Maximum number of users reached.
#	    3012 - Specified email address is already assigned to another user.
#	    3014 - Creation of a user for the root customer (CustomerID 1) is not permitted.
#	    3014 - When adding a user, must not be an LDAP user.
#		3020 - Account is locked
#		3022 - Customer/Site already exists.
#		3026 - Customer name length has exceeded 120 characters.
#		4000 - SessionID not found or has expired.
#	    5000 - An unexpected exception occurred.
#		5000 - Query failed.
#		5000 - javax.validation.ValidationException: Unable to validate UI session
#    	9910 - Service Organization already exists.
#
		
		Break
	}
	#EndRegion Support - Connection

	#Region Support - SOAP
	## SOAP API Requests
	hidden [Object]NCWebRequest([String]$APIMethod,[String]$APIData){
		Return $this.NCWebRequest($APIMethod,$APIData,'')
	}

	hidden [Object]NCWebRequest([String]$APIMethod,[String]$APIData,$Version){
		## Basic NCentral SOAP-request, invoking Credentials.

		## Optionally invoke version (specific requests)
		#version - Determines whether MSP N-Central or PSA credentials are to be used. In the case of PSA credentials the number indicates the type of PSA integration setup.
		#	"0.0" indicates that MSP N-central credentials are to be used.
		#	"1.0" indicates that a ConnectWise PSA integration is to be used.
		#	"2.0" indicates that an Autotask PSA integration is to be used.
		#	"3.0" indicates that a Tigerpaw PSA integration is to be used.
		#
		$VersionKey = ''
		If($Version){
			$VersionKey = ("
					    <ei2:version>{0}</ei2:version>" -f $Version)
		}

		## Build SoapRequest (Ending Here-String ("@) must always be left-lined.)
		$MySoapRequest =(@"
<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" xmlns:ei2="http://ei2.nobj.nable.com/">
	<soap:Header/>
	<soap:Body>
		<ei2:{0}>{4}
			<ei2:username>{1}</ei2:username>
			<ei2:password>{2}</ei2:password>{3}
		</ei2:{0}>
	</soap:Body>
</soap:Envelope>
"@ -f $APIMethod, $this.PlainUser(), $this.PlainPass(), $APIData, $VersionKey)

		#Write-host $MySoapRequest				## Debug purposes.
		#$this.Testvar = $MySoapRequest				## Debug purposes.
		## Set the Request-properties in a local Dictionary / Hash-table.
		$RequestProps = @{}
		$RequestProps.Method = "Post"
		$RequestProps.Uri = $this.SoapURL
		$RequestProps.TimeoutSec = $this.RequestTimeOut
		$RequestProps.body =  $MySoapRequest

		$FullReponse = $null
		Try{
				#$FullReponse = Invoke-RestMethod -Uri $this.SoapURL -body $MySoapRequest -Method POST
				$FullReponse = Invoke-RestMethod @RequestProps
			}
#		Catch [System.Net.WebException]{
#			    Write-Host ([string]::Format("Error : {0}", $_.Exception.Message))
#				$this.Error = $_
#				$this.ErrorHandler()
#			}
		Catch {
			    Write-Host ([string]::Format("Error : {0}", $_.Exception.Message))
				$this.Error = $_
				$this.ErrorHandler()
			}
							
		#$ReturnProperty = $$APIMethod + "Response"
		$ReturnClass = $FullReponse.envelope.body | Get-Member -MemberType Property
		$ReturnProperty = $ReturnClass[0].Name
				
		Return 	$FullReponse.envelope.body.$ReturnProperty.return
	}

	hidden [Object]NCVersionRequest(){
		$Version = $null

		## Use versionInfoGet, Includes checking SOAP-connection
		## No credentials needed (yet).
		$APIMethod = "versionInfoGet"
		$VersionEnvelope = (@"
			<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" xmlns:ei2="http://ei2.nobj.nable.com/">
				<soap:Header/>
				<soap:Body>
					<ei2:{0}/>
				</soap:Body>
			</soap:Envelope>
"@ -f $APIMethod)		## End of Here-String must be left-lined.

		## Set the Request-properties in a local Dictionary / Hash-table.
		$RequestProps = @{}
		$RequestProps.Method = "Post"
		$RequestProps.Uri = $this.SoapURL
		$RequestProps.TimeoutSec = $this.RequestTimeOut
		$RequestProps.body =  $VersionEnvelope

		Try{
			$Version = (Invoke-RestMethod @RequestProps).envelope.body.($APIMethod + "Response").return |
				Select-Object key,value

			## Additional connection-info available using Invoke-WebRequest
			#$this.Testvar = Invoke-WebRequest @RequestProps
			#Write-Host ("Security Protocols Used = {0} " -f [Net.ServicePointManager]::SecurityProtocol)

			## Same Version info using WebRequest iso RestMethod
			#$Version = ([XML](Invoke-WebRequest @RequestProps).Content).envelope.body.($APIMethod + "Response").return |
			#	Select-Object key,value

		}
#		Catch [System.Net.WebException]{
#			$this.Error = $_
#			$this.ErrorHandler()
#		}
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}

		Return $Version
	}

	hidden [Object]GetNCData([String]$APIMethod,[String]$Username,[String]$PassOrJWT,$KeyPairs){
		## Overload for Backward compatibility only
		Return $this.GetNCData($APIMethod,$KeyPairs,'')
	}

	hidden [Object]GetNCData([String]$APIMethod,[Array]$KeyPairs){

		Return $this.GetNCData($APIMethod,$KeyPairs,'')
	}
		
	hidden [Object]GetNCData([String]$APIMethod,[Array]$KeyPairs,[String]$Version){

		## Process Keys to Request-settings
		$MyKeys=""
		If ($KeyPairs){
			ForEach($KeyPair in $KeyPairs){ 
				## KeyValue can be an array with multiple values
				$MyValues=""
				ForEach($KeyValue in $KeyPair.value){
					$MyValues = $MyValues + ("
				<ei2:value>{0}</ei2:value>" -f $KeyValue)
				}

				$MyKeys = $MyKeys + ("
			<ei2:settings>
				<ei2:key>{0}</ei2:key>{1}
			</ei2:settings>" -f $KeyPair.Key, $MyValues)
			}
		}
		## Invoke request
		Return $this.NCWebRequest($APIMethod, $MyKeys,$Version)
	}

	hidden [Object]GetNCDataOP([String]$APIMethod,[Array]$CustomerIDs,[Boolean]$ReverseOrder){
		## Get OrganizationProperties for (optional) specified customerIDs
		## Process Array
		$MyKeys=""
		ForEach($CustomerID in $CustomerIDs){ 
			$MyKeys += ("
			<ei2:customerIds>{0}</ei2:customerIds>" -f $CustomerID)
		}
		## Add mandatory options
		$MyKeys += ("
			<ei2:reverseOrder>{0}</ei2:reverseOrder>" -f ($ReverseOrder.ToString()).ToLower())

		## Invoke request
		Return $this.NCWebRequest($APIMethod, $MyKeys)
	}

	hidden [Object]GetNCDataDP([String]$APIMethod,[Array]$DeviceIDs,[Array]$DeviceNames,[Array]$FilterIDs,[Array]$FilterNames,[Boolean]$ReverseOrder){
		## Get DeviceProperties for (optional) filtered devices
		## Process Arrays
		$MyKeys=""

		If($DeviceIDs){
			ForEach($DeviceID in $DeviceIDs){ 
				$MyKeys += ("
			<ei2:deviceIDs>{0}</ei2:deviceIDs>" -f $DeviceID)
			}
		}

		If($DeviceNames){
			ForEach($DeviceName in $DeviceNames){ 
				$MyKeys += ("
			<ei2:deviceNames>{0}</ei2:deviceNames>" -f $DeviceName)
			}
		}

		If($FilterIDs){
			ForEach($FilterID in $FilterIDs){ 
				$MyKeys += ("
			<ei2:filterIDs>{0}</ei2:filterIDs>" -f $FilterID)
			}
		}

		If($FilterNames){
			ForEach($FilterName in $FilterNames){ 
				$MyKeys += ("
			<ei2:filterNames>{0}</ei2:filterNames>" -f $FilterName)
			}
		}

		$MyKeys += ("
			<ei2:reverseOrder>{0}</ei2:reverseOrder>" -f ($ReverseOrder.ToString()).ToLower())

		## Invoke request
		Return $this.NCWebRequest($APIMethod, $MyKeys)
	}

	hidden [Object]SetNCDataOP([String]$APIMethod,$OrganizationID,$OrganizationPropertyID,[String]$OrganizationPropertyValue){
		## Set a single OrganizationProperty
		## Process Arrays
		$MyKeys=("
			<ei2:organizationProperties>
				<ei2:customerId>{0}</ei2:customerId>
				<ei2:properties>
					<ei2:propertyId>{1}</ei2:propertyId>
					<ei2:value>{2}</ei2:value>
				</ei2:properties>
			</ei2:organizationProperties>" -f $OrganizationID,$OrganizationPropertyID,$OrganizationPropertyValue)

		## Invoke request
		Return $this.NCWebRequest($APIMethod, $MyKeys)
	}

	hidden [Object]SetNCDataDP([String]$APIMethod,$DeviceID,$DevicePropertyID,[String]$DevicePropertyValue){
		## Set a single DeviceProperty
		## Process Arrays
		$MyKeys=("
			<ei2:deviceProperties>
				<ei2:deviceID>{0}</ei2:deviceID>
				<ei2:properties>
					<ei2:devicePropertyID>{1}</ei2:devicePropertyID>
					<ei2:value>{2}</ei2:value>
				</ei2:properties>
			</ei2:deviceProperties>" -f $DeviceID, $DevicePropertyID, $DevicePropertyValue)

		## Invoke request
		Return $this.NCWebRequest($APIMethod, $MyKeys)
	}
	#EndRegion Support - SOAP

	#Region Support - REST
	[void]NCRestAuthenticate(){
		$AuthPath = "/auth/authenticate"

		## Initialize Header for token-request
		$Headers = @{}
		$Headers.Authorization = ("Bearer {0}" -f $this.PlainPass())
		$Headers.Accept = "*/*"
		$this.MyHeaders = $Headers

		# Request access token
		$Response = $null
		Try {
			$Response = $this.NCRestRequest($AuthPath,"Post",$false)
			#$Response = $this.NCRestRequest($AuthPath,"Post",$false,@{},$false,10)
		}
		Catch {
			$AuthURL = ("{0}{1}" -f $this.RestURL, $AuthPath)
			Write-Host ("`r`nNot successfully authenticated REST-API to {0}.`r`n" -f $AuthURL) -ForegroundColor Red -BackgroundColor DarkBlue
			$this.ForceSOAP = $true
#				$_.Exception
		}

		# Save Request-token information for Data-Requests.
		$this.MyHeaders.Authorization = ("Bearer {0}" -f $Response.tokens.access.token)
		$this.TokenExpiration = Get-Date (Get-date).addseconds($Response.tokens.access.expiryseconds)

	}

	[Object]NCRestRequest([String]$customURL){
		$Method = "Get"
		$Retry = $true
		$customBody = @{}
		$Paged = $false
		$PageLimit = $this.PageMaxSize
		Return $this.NCRestRequest($customURL,$Method,$Retry,$customBody,$Paged,$PageLimit)
	}

	[Object]NCRestRequest([String]$customURL,[String]$Method){
		$Retry = $true
		$customBody = @{}
		$Paged = $false
		$PageLimit = $this.PageMaxSize
		Return $this.NCRestRequest($customURL,$Method,$Retry,$customBody,$Paged,$PageLimit)
	}

	[Object]NCRestRequest([String]$customURL,[String]$Method,[Boolean]$Retry){
		$customBody = @{}
		$Paged = $false
		$PageLimit = $this.PageMaxSize
		Return $this.NCRestRequest($customURL,$Method,$Retry,$customBody,$Paged,$PageLimit)
	}

	[Object]NCRestRequest([String]$customURL,[String]$Method,[Boolean]$Retry,[Hashtable]$customBody){
		$Paged = $false
		$PageLimit = $this.PageMaxSize
		Return $this.NCRestRequest($customURL,$Method,$Retry,$customBody,$Paged,$PageLimit)
	}

	[Object]NCRestRequest([String]$customURL,[String]$Method,[Boolean]$Retry,[Hashtable]$customBody,[Boolean]$Paged){
		$PageLimit = $this.PageMaxSize
		Return $this.NCRestRequest($customURL,$Method,$Retry,$customBody,$Paged,$PageLimit)
	}

	[Object]NCRestRequest([String]$customURL,[String]$Method,[Boolean]$Retry,[Hashtable]$customBody,[Boolean]$Paged,[Int32]$PageLimit){

		$NCDataUri = ("{0}{1}" -f $this.RestURL,$customURL)

		## Input Validation
		$RefreshToken = $false
#		If(!$this.MyHeaders){
#			Write-Host "Token-init"
#			$RefreshToken = $true
#			#$this.NCRestAuthenticate()
#		}
	
		If($customURL -ne "/auth/authenticate"){
			$CurrDate = Get-Date(Get-Date).AddSeconds(15)
			$TokenDate = $this.TokenExpiration
			If($TokenDate -lt $CurrDate){
				Write-Host "Access-Token renew"
				$RefreshToken = $true
			}
		}

		If($RefreshToken){
			$this.NCRestAuthenticate()
		}

		## Request Data
		$ConnProps = @{}                             ## Dictionary / Hash-table to hold request-properties/parameters
		$ConnProps.URI = $NCDataUri
		$ConnProps.Method = $Method
		$ConnProps.Body = $customBody				## modified inside request-loop for paging
		$ConnProps.Headers = $this.myheaders		## including token
		$ConnProps.TimeOutSec = $this.RequestTimeOut

		$Items = $null

		If ($Paged){
			# Add Paging-parameters to body
			$customBody.pageSize = $PageLimit				## Returned items per page.
			If($this.PageMaxSize -lt $PageLimit){
				$customBody.pageSize = $this.PageMaxSize		## Modify if pre-set maximum is lower then specified limit.
			}

			$Page = 1
			$customBody.pageNumber = $Page
			$Items1 = $null
			$ItemProperty = ""
			Do {
				$ConnProps.Body = $customBody

				Write-Host ("Retrieving page {0} from: {1}" -f $page, $ConnProps.URI )	## For debug

				If($Retry){
					$Items1 = $this.NCDataRequestRetry($ConnProps)
				}
				Else {
					$Items1 = $this.NCDataRequestPlain($ConnProps)
				}
				
				$ItemProperty = "data"
				$Items += $Items1.($ItemProperty)

				$Page += 1
				$customBody.pageNumber = $Page


			} While($Items1._links.nextPage)
#			} While($Items1.itemCount -eq $Items1.pageSize)
		}
		Else {
			## Not Paged
			If($Retry){
				$Items = $this.NCDataRequestRetry($ConnProps)
			}
			Else {
				$Items = $this.NCDataRequestPlain($ConnProps)
			}
		}

		Return $Items
	}

	[Object]NCDataRequestRetry([HashTable]$ConnProps){
		$Items=$null

		$Retries = 5
		Do{
			try {
				$Items = Invoke-RestMethod @ConnProps
				$Retries = 0			## Exit Retry-loop on success
			}
			catch {
				$Retries--				## Lower Retries left
				If ($Retries){
					Write-Host ("Connection Error; Re-authenticating {0}" -f $Retries)
					$this.NCRestAuthenticate()
					## Use updated info for re-try
					$ConnProps.Headers = $this.myheaders
				}Else{
					Write-Host ("Error : {0}" -f $_.Exception.Message)
					$this.Error = $_
					$this.ErrorHandler()
				}
			}
		}While($Retries)

		Return $Items
	}

	[Object]NCDataRequestPlain([HashTable]$ConnProps){
		$Items = $null
		try {
			$Items = Invoke-RestMethod @ConnProps
		}
		catch {
			Write-Host ("Error : {0}" -f $_.Exception.Message)
			$this.Error = $_
			$this.ErrorHandler()
		}

		Return $items
	}

	#EndRegion Support - REST

	#Region Support - Data Processing
    ## Data Management / Processing

	hidden[PSObject]ProcessData1([Array]$InArray){
		Return $this.ProcessData1($InArray,$false)
	}

	<#
	hidden[PSObject]ProcessData1([Array]$InArray,[String]$PairClass){
		Return $this.ProcessData1($InArray,$PairClass,$false)
	}
	#>

	hidden[PSObject]ProcessData1([Array]$InArray,[Boolean]$ShowProgress){
		## Most Common PairClass is Info or Item.
		## Fill if not specified.

		# Hard (Pre-)Fill / Default
		$PairClass = "info"

		## Base on found Array-Properties if possible
		If($InArray.Count -gt 0){
			## Only one property exists at this level. The name of this property specifies the DeviceClass.
			#$PairClass = ($InArray[0] | Get-member -MemberType Property).Name
			$PairClass = ($InArray[0] | Get-member -MemberType Property)[0].Name
		}
		
		Return $this.ProcessData1($InArray,$PairClass,$ShowProgress)
	}
	
	hidden[PSObject]ProcessData1([Array]$InArray,[String]$PairClass,[Boolean]$ShowProgress){
		
		## Received Dataset KeyPairs 2 List/Columns
		#$OutObjects = @()
		[System.Collections.Generic.List[Object]]$OutObjects = @()
		
		if ($InArray){

			$TotalObjects=$InArray.Count					## For progress-indicator
			$CurrentObject = 0
			## Process all items
			[System.Collections.ArrayList]$AllColumns = @()	## To fix issue with different # of object-properties.
			foreach ($InObject in $InArray) {

				If($ShowProgress){
					$CurrentObject +=1
					#Write-host ("Processing {0} of {1} devices." -f $CurrentObject, $TotalObjects) 
					$CompletedPercent = ($CurrentObject / $TotalObjects)*100
					Write-Progress -Activity ("Processing {0} Objects."-f $TotalObjects) -Status ("{0:N1}% Complete:" -f $CompletedPercent)  -PercentComplete $CompletedPercent
					#Start-Sleep -Milliseconds 250
				}

#				$ThisObject = New-Object PSObject			## In this routine the object is created at start. Properties are added with values.
				$Props = @{}								## In this routine the object is created at the end. Properties from a list/Hashtable.

				## Add a Reference-Column at Object-Level (for Custom Properties)
				If ($PairClass -eq "Properties"){
					## Add reference to customer or device from the top-level.

					## CustomerLink if Available
					if(Get-Member -inputobject $InObject -name "CustomerID"){
#						$ThisObject | Add-Member -MemberType NoteProperty -Name 'CustomerID' -Value $InObject.CustomerID -Force
						$Props.CustomerID = $InObject.CustomerID
						$AllColumns += 'CustomerID'
					}
					## DeviceLink if Available
					if(Get-Member -inputobject $InObject -name "DeviceID"){
#						$ThisObject | Add-Member -MemberType NoteProperty -Name 'DeviceID' -Value $InObject.DeviceID -Force
						$Props.DeviceID = $InObject.DeviceID
						$AllColumns += 'DeviceID'
					}
				}

				## Convert all (remaining) keypairs to Properties
				## issue here with Pairclass 'Properties' when properties-column is empty (only possible with devices/CDPs) --> Foreach is skipped
				
				foreach ($item in $InObject.$PairClass) {

					## Cleanup the Key (Header) and/or Value before usage.
					If ($PairClass -eq "Properties"){
						$Header = $item.label
					}
					Else{
						If($item.key.split(".")[0] -eq 'asset'){	##Should use ProcessData2 (ToDo)
							$Header = $item.key
						}
						Else{
							$Header = $item.key.split(".")[1]
						}
					}

					## Fill the array of all Unique headers for output (FixProperties).
					#$AllColumns += $Header								--> Disabled for speed-effect. Use 'Fixproperties' after return instead.
					# Only unique HeaderNames allowed
					#$AllColumns = $AllColumns | Sort-Object -Unique	--> Breaks the module.

					## Ensure a Flat/String Value of multiple entries for now --> work to do?
					If ($item.value -is [Array]){
						#$DataValue = $item.Value[0]
						$DataValue = $item.Value -join ","
					}
					Else{
						$DataValue = $item.Value
					}

					## Now add the Key/Value pairs. (When using the 'pre-defined Object' option. )
#					$ThisObject | Add-Member -MemberType NoteProperty -Name $Header -Value $DataValue -Force

 					# if a key is found that already exists in the hashtable
			        if ($Props.ContainsKey($Header)) {
			            # either overwrite the value 'Last-One-Wins'
			            # or do nothing 'First-One-Wins'
			            #if ($this.allowOverwrite) { $Props[$Header] = $DataValue }
			        }
			        else {
			            #$Props[$Header] = $DataValue
						#$Props.add($Header,$DataValue)
						$Props.$Header = $DataValue
			        }					
				}

				## Add the Object to the list
				#$ThisObject = New-Object -TypeName PSObject -Property $Props	
				#$OutObjects += $ThisObject
				$OutObjects += [PSCustomObject]$Props		#Create object from hash-table

				## !! Only Properties of the first object seem used for return !! --> If objects with no properties at all are included.
			}

<#
			## Attempt to fix 'Properties from first object only' issue.
			## breaks $outobjects now		

			If($AllColumns){
				## Unify all Object-properties
				#$AllColumns = $AllColumns | Sort-Object -Unique

				## Deal with long-names containing spaces. (Custom Properties mainly)
				[String]$ColumnString = $AllColumns -join "," 
				$OutObjects = $OutObjects | Select-Object $ColumnString.split(",")
			}
#>
			## Convert Date-fields of root-object
			$OutObjects = $this.FixDates($OutObjects)

			If($ShowProgress){
				#Write-Progress -Activity ("Processed {0} Objects."-f $OutObjects.count) -Status "Ready"
				#Start-Sleep -Milliseconds 1000
				Write-Progress -Activity ("Processed {0} Objects."-f $OutObjects.count) -Status "Ready" -Completed
			}
		}

		## Return the list of Objects
		Return $OutObjects
		#Return $this.FixProperties($OutObjects)
	}

	hidden[PSObject]ProcessData2([Array]$InArray){

		Return $this.ProcessData2($InArray,$false)
	}

	hidden[PSObject]ProcessData2([Array]$InArray,[Boolean]$ShowProgress){
		## Most Common PairClass is Info or Item.
		## Fill if not specified.
		
		# Hard (Pre-)Fill
		$PairClass = "info"

		## Base on found Array-Properties if possible
		If($InArray.Count -gt 0){
			$PairClasses = $InArray[0] | Get-member -MemberType Property
			$PairClass = $PairClasses[0].Name
		}

		Return $this.ProcessData2($InArray,$PairClass,$ShowProgress)
	}

	hidden[PSObject]ProcessData2([Array]$InArray,[String]$PairClass,[Boolean]$ShowProgress){

		## Convert Received Dataset KeyPairs to a multi-level Object
		## Key-structure: asset.service.caption.28
		##				service	- Property or Sub-object
		##				caption - key
		##				##		- Service-item (sub-identifier)
		## 
		## Each Asset in dataset is processed sepearately and added to the output.

		## Output-List
		#$OutObjects = @()
		[System.Collections.Generic.List[Object]]$OutObjects = @()
		
		## Inputcheck - is there any data to process?
		If ($InArray){

			$TotalObjects=$InArray.Count
			$CurrentObject = 0
			## Process all devices
			ForEach ($Object in $InArray){

				If($ShowProgress){
					$CurrentObject +=1
					#Write-host ("Processing {0} of {1} devices." -f $CurrentObject, $TotalObjects) 
					$CompletedPercent = ($CurrentObject / $TotalObjects)*100
					Write-Progress -Activity ("Processing {0} Objects."-f $TotalObjects) -Status ("{0:N1}% Complete:" -f $CompletedPercent)  -PercentComplete $CompletedPercent
					#Start-Sleep -Milliseconds 250
				}

				## Get the DeviceId to repeat in every Object/Array-Property
				$CurrentDeviceID = ($Object.$PairClass | Where-Object {$_.key -eq 'asset.device.deviceid'}).value
				#Write-Debug "DeviceObject CurrentDeviceID: $CurrentDeviceID"
				
				## Sort keys for before processing. Column 2 and 4
				$SortedInfo = $Object.$PairClass | Sort-Object @{Expression={$_.key.split(".")[1] + $_.key.split(".")[3]}; Descending=$false}

				## Init
				$Props = @{}		## In this routine the object is created at the end. Properties from this list.

				## For processing properties and additional identifiers (column4)
				$OldArrayID = ""
				[Array]$ArrayProperty = $null
				$OldArrayItemID = ""
				[HashTable]$ArrayItemProperty = $null


				## Convert the key/value-pairs to a Multi-Layer Object with Properties
				ForEach ($KeyPair in $SortedInfo) {

					## Key-structure: asset.service.caption.28
					## Outer-loop differenting on column 2		MainObject Array-Property
					## Inner-loop differenting on column 4		
					## ObjectItem is column 2.4  (easysplit)	Array-ItemID
					## ObjectHeaders are Column 3				Array-Item-PropertyHeader
					## ObjectValue = Value						
						
					## Treat 'device' as Root
					## Add Sub-objects for all other headers
					## Add deviceid to each sub-object for easy reference
					## Add property direct to sub-object if column4 (index) does not exist
					## Build and Add an Array-property to sub-object if column4 is an int

					$KeySplit = $KeyPair.key.split(".")
					$KeyValue = $KeyPair.value

					If(($KeySplit[1]) -eq 'device'){
						## Add device-properties to the root as a Non-Array.
						$Header = $KeySplit[2]

						## Ensure a Flat (character-separated) Value for now --> work to do?
						If ($KeyValue -is [Array]){
							$Props.$Header = $KeyValue -join ","
						}
						Else{
							$Props.$Header = $KeyValue
						}
						
					}
					Else{
						## Add property as an (Array of) Object(s).
						## Make an object-Array Before Adding to root
												
						## Create the unique Property ItemID from the Key-Name
						If($KeySplit[3]){
							## Property has index-column
							$ArrayItemId = ("{0}.{1}" -f $KeySplit[1], $KeySplit[3])
						}
						Else{
							## No index-column
							$ArrayItemId = $KeySplit[1]
						}

						## Is this a new Array-Item?
						If($ArrayItemId -ne $OldArrayItemID){
							## Add the current object to the array-property and start over
							If($OldArrayItemID -ne ""){
								$ArrayItem = New-Object -TypeName PSObject -Property $ArrayItemProperty
								$ArrayProperty += $ArrayItem
							}							
							## (Re-)Init
							$ArrayItemProperty = @{}
							$OldArrayItemID = $ArrayItemId
							## Add an unique ID-Column and the DeviceID to the item.
							$ArrayItemProperty.ItemId=$ArrayItemId
							$ArrayItemProperty.DeviceId=$CurrentDeviceID
						}

						## Create the Main Property Name from the Key-Name
						$ArrayId = $KeySplit[1]
						## Is this a new Array?
						If($ArrayId -ne $OldArrayID){
							## Add the current array to the main object and start a new one
							If($OldArrayID -ne ""){
								#Write-Debug "ArrayId = $ArrayId"
								$Props.$OldArrayId = $ArrayProperty
							}
							## (Re-)Init
							$ArrayProperty = $null
							$OldArrayID = $ArrayId
						}

						## Add the current item to the array-item
						$Header2 = $KeySplit[2]
						$ArrayItemProperty.$Header2=$KeyValue

					}
				
				## End of Keypairs-loop
				}

				## Build object for last ArrayItem too
				If($ArrayItemProperty){
					$ArrayItem = New-Object -TypeName PSObject -Property $ArrayItemProperty
					$ArrayProperty += $ArrayItem
				}

				## Add the last build array to the main Object
				If($ArrayProperty){
					$Props.$OldArrayId = $ArrayProperty
				}

				## Create the Multi-layer Object, using the generated properties.
				#$ThisObject = New-Object -TypeName PSObject -Property $Props
				## Add the Multi-layer Object to the Output-list
				#$OutObjects += $ThisObject
				$OutObjects += [PSCustomObject]$Props		#Create object straight from hash-table

			## End of Objects-loop - Get Next
			}

			## Convert all Date-fields of root-object from string to date
			$OutObjects = $this.FixDates($OutObjects)

			If($ShowProgress){
				Write-Progress -Activity ("Processed {0} Objects."-f $OutObjects.count) -Status "Ready" -Completed
				#Start-Sleep -Milliseconds 250
			}

		## End of Input-check / process data
		}

		## Return the list of Objects
		Return $OutObjects
	}

	[PSObject]IsEncodedBase64([string]$InputString){
		## UniCode by default
		Return $this.IsEncodedBase64($InputString,$false)
	}

	[PSObject]IsEncodedBase64([string]$InputString,[Boolean]$UTF8){

		#[OutputType([Boolean])]
		$DataIsEncoded = $true
	
			Try{
				## Try Decode
				If($UTF8){
					[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($InputString)) | Out-Null
				}
				Else{
					[System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($InputString)) | Out-Null
				}
			}
			Catch{
				## Data was not encoded yet
				$DataIsEncoded = $false
			}
	
		Return $DataIsEncoded
	}

	[PSObject]ConvertBase64([String]$Data){
		## Encode and Unicode as default
		Return $this.ConvertBase64($Data,$false,$false)
	}

	[PSObject]ConvertBase64([String]$Data,[Bool]$Decode){
		## Unicode as default
		Return $this.ConvertBase64($Data,$Decode,$false)
	}

	[PSObject]ConvertBase64([String]$Data,[Bool]$Decode,[Bool]$UTF8){
	
		## Init
		[string]$ReturnData = $Data
		$DataIsEncrypted = $true			
	
		If($Data){
			## Test content to avoid double-encoding.
			## Still needs some work for false positives. Now checks for valid code-length mainly.
			## Encoded without Byte Order Mark (BOM). Makes recognition difficult.
			Try{
				## Try Decode
				If($UTF8){
					$ReturnData = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Data))
				}
				Else{
					$ReturnData = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($Data))
				}
			}
			Catch{
				## Data was not valid encoded yet
				$DataIsEncrypted = $false
			}

			## If data should not be decrypted.
			If (!$Decode){
				If ($DataIsEncrypted){
					## Return Already Encrypted Data
					$ReturnData = $Data
				}
				Else{
					## Return Newly Encrypted Data
					If($UTF8){
						$Bytes = [System.Text.Encoding]::UTF8.GetBytes($Data)
					}
					Else {
						$Bytes = [System.Text.Encoding]::Unicode.GetBytes($Data)
					}
					$Returndata = [System.Convert]::ToBase64String($Bytes)
				}
			}
		}

		Return $Returndata
	}
	
    [PSObject]FixProperties([Array]$ObjectArray){
        ## Unifies the properties for all Objects.
        ## Solves Format-Table and Export-Csv issues not showing all properties.

        $ReturnData = $ObjectArray

		If ($ReturnData){
	
			[System.Collections.ArrayList]$AllColumns=@()
			# Walk through all Objects for Property-names
			$counter = $Returndata.length
			for ($i=0; $i -lt $counter ; $i ++){
				# Get the Property-names
				$Names = ($ReturnData[$i] |Get-Member -type Noteproperty,Property -ErrorAction SilentlyContinue).name

				# Add New or Replace Existing 
				$counter2 = $names.count
				for ($j=0; $j -lt $counter2 ; $j ++){
					$AllColumns += $names[$j]
				}
				# Only unique ColumnNames allowed
				$AllColumns = $AllColumns | Sort-Object -Unique
			}

			If($AllColumns){
				## Deal with long-names containing spaces. (Custom Properties mainly)
				[String]$ColumnString = $AllColumns -join "," 
				$ReturnData = $ReturnData | Select-Object $ColumnString.split(",")
			}
		}

		Return $ReturnData
    }

    [PSObject]FixDates([Array]$ObjectArray){
        ## Coverts date-strings to Date-properties

        $ReturnData = $ObjectArray

		## Convert all Time-fields to real dates if possible.
		[System.Collections.ArrayList]$TimeFields = @()
		try{$TimeFields.AddRange(($ReturnData[0]|Get-Member -type Noteproperty -ErrorAction SilentlyContinue).name -like "*Time")}catch{}
		try{$TimeFields.AddRange(($ReturnData[0]|Get-Member -type Noteproperty -ErrorAction SilentlyContinue).name -like "*Date")}catch{}
		try{$TimeFields.AddRange(($ReturnData[0]|Get-Member -type Noteproperty -ErrorAction SilentlyContinue).name -like "*Don")}catch{}
		#$TimeFields.Add("createdon")
		If($TimeFields.count -gt 1){
			$TimeFields = $TimeFields | Select-Object -unique
		}
	
		#Write-Host $TimeFields		## Debug
		If($TimeFields){
			ForEach ($TimeField in $TimeFields){
				ForEach ($Object in $ReturnData){
					If($Object.$TimeField){		## has value?
						try {
							$Object.$TimeField = [datetime]$Object.$TimeField
						}
						catch {
							## Nothing on error
						}
					}
				}
			}
		}

        Return $ReturnData
	}
	#EndRegion Support - Data Processing

	#EndRegion ClassSupport

	#Region RestData
	## Methods named after the API-path
		
	[Object]ApiGet(){
		## Can be used for URL-validation
		$DataPath = ""
		$ApiData = ($this.NCRestRequest($DataPath,"Get",$true))._links	## NoPaging/filter

		## Create a list of Objects - for easier lookup
		$ApiNames = ($ApiData | Get-Member -type NoteProperty).name
		$ApiList = @()
		ForEach ($Name in $ApiNames){
			#Write-Host ("{0},{1}" -f $name, $ApiData.($Name))
			$ApiListItem = @{}
			$ApiListItem.Apiname = $Name
			$ApiListItem.Apivalue = $ApiData.($Name)

#			$ApiList += New-Object -TypeName PSObject -Property $ApiListItem
			$ApiList += [PSCustomObject]$ApiListItem
		}

		Return $ApiList
	}


	[Object]OrgUnitsGet(){
		$DataPath = "/org-units"
		$this.rc = $this.NCRestRequest($DataPath,"Get",$true,@{},$true)

		return $this.rc			# Plain Return for now
		#return $this.ProcessData1($this.rc)
	}

	[Object]OrgUnitsGet([Int32]$OrgUnitID){
		$DataPath = ("/org-units/{0}" -f $OrgUnitID)
		Return $this.NCRestRequest($DataPath,"Get",$true)		## NoPaging/filter
	}

	[Object]OrgUnitsCustomPropertiesGet([Int32]$OrgUnitID){
		$DataPath = ("/org-units/{0}/custom-properties" -f $OrgUnitID)
		return $this.NCRestRequest($DataPath,"Get",$true,@{},$true) |
								Select-Object @{n="OrgUnitID"; e={$OrgUnitID}},* 			## OrgUnitID added to Property Info
	}

	[Object]OrgUnitsCustomPropertiesGet([Int32]$OrgUnitID,[Int32]$PropertyID){
		$DataPath = ("/org-units/{0}/custom-properties/{1}" -f $OrgUnitID, $PropertyID)
		return $this.NCRestRequest($DataPath,"Get",$true,@{},$false) |
								Select-Object @{n="OrgUnitID"; e={$OrgUnitID}},* 			## OrgUnitID added to Property Info
	}

	[Object]OrgUnitsUserRolesGet([Int32]$OrgUnitID){
		$DataPath = ("/org-units/{0}/user-roles" -f $OrgUnitID)
		return $this.NCRestRequest($DataPath,"Get",$true,@{},$true)
	}

	[Object]OrgUnitsUserRolesGet([Int32]$OrgUnitID,[Int32]$UserRoleID){
		$DataPath = ("/org-units/{0}/user-roles/{1}" -f $OrgUnitID,$UserRoleID)
		return $this.NCRestRequest($DataPath,"Get",$true,@{},$false)
	}

	[Object]OrgUnitsAccessGroupsGet([Int32]$OrgUnitID){
		$DataPath = ("/org-units/{0}/access-groups" -f $OrgUnitID)
		return $this.NCRestRequest($DataPath,"Get",$true,@{},$true)
	}

	[Object]OrgUnitsUsersGet([Int32]$OrgUnitID){
		$DataPath = ("/org-units/{0}/users" -f $OrgUnitID)
		Return $this.NCRestRequest($DataPath,"Get",$true,@{},$true)
	}

	[Object]OrgUnitsRegistrationTokenGet([Int32]$OrgUnitID){
		$DataPath = ("/org-units/{0}/registration-token" -f $OrgUnitID)
		Return $this.NCRestRequest($DataPath,"Get",$true,@{},$false)
	}

	[Object]OrgUnitsJobStatussesGet([Int32]$OrgUnitID){
		$DataPath = ("/org-units/{0}/job-statuses" -f $OrgUnitID)
		Return $this.NCRestRequest($DataPath,"Get",$true,@{},$true)
	}

	[Object]OrgUnitsDevicesGet([Int32]$OrgUnitID){
		$DataPath = ("/org-units/{0}/devices" -f $OrgUnitID)

		$Select= @"
deviceClass=="Servers - Windows"
"@

		$Select= @"
deviceClass=like='Servers*'
"@

		Write-host $select

		$Body = @{}
		#$Body.filterId = 41					## Filter works. Other to test
#		$Body.select = $Select
		#$Body.select = 'longName=="ODRICA01"'	#501102-56599
		#$Body.sortBy = "deviceID"

		return $this.NCRestRequest($DataPath,"Get",$true,$Body,$true)
	}

	[Object]OrgUnitsChildrenGet([Int32]$OrgUnitID){
		$DataPath = ("/org-units/{0}/children" -f $OrgUnitID)
		Return $this.NCRestRequest($DataPath,"Get",$true,@{},$true)
	}

	[Object]OrgUnitsActiveIssuesGet([Int32]$OrgUnitID){
		$DataPath = ("/org-units/{0}/active-issues" -f $OrgUnitID)
		Return $this.NCRestRequest($DataPath,"Get",$true,@{},$true)
	}


	[Object]DevicesGet([Int32]$CustomerID){
		$DataPath = "/devices"
		#$DataPath = ("/devices?select=customerId=={0}" -f $CustomerID)
		#"$apiUrl/api/devices?select=customerId%3D%3D$customerID"	## from Example: https://me.n-able.com/s/article/NC-Rest-API-Get-Filters  

		$Body = @{}
		#$Body.filterId = 41					## Filter works.
		#$Body.select = $Select
#		$Body.select = 'longName=="ODRICA01"'	## Waiting for version 2024.4
		$Body.select = ("customerId=={0}" -f $CustomerID)
		$Body.sortBy = "longName"				## Sort works
		$Body.sortOrder = "ASC"					## asc, ascending, natural, desc, descending, reverse

		return $this.NCRestRequest($DataPath,"Get",$true,$Body,$false)
	}

	[Object]DevicesCustomPropertiesGet([Int32]$DeviceID){
		$DataPath = ("/devices/{0}/custom-properties" -f $DeviceID)
		$CPList = $this.NCRestRequest($DataPath,"Get",$true,@{},$true) |
					Select-Object @{n="deviceID"; e={$DeviceID}},* 			## DeviceID added to each property

		return $CPList
		#return $this.FixProperties($CPList)
	}

	[Object]DevicesServiceMonitorStatusGet([Int32]$DeviceID){
		$DataPath = ("/devices/{0}/service-monitor-status" -f $DeviceID)
		$SMSList = $this.NCRestRequest($DataPath,"Get",$true,@{},$true) #|
#					Select-Object @{n="deviceID"; e={$DeviceID}},* 			## DeviceID added to each Servicemonitor

		return $SMSList
	}

	[Object]DevicesScheduledTasksGet([Int32]$DeviceID){
		$DataPath = ("/devices/{0}/scheduled-tasks" -f $DeviceID)
		$STList = $this.NCRestRequest($DataPath,"Get",$true,@{},$true) #|
#					Select-Object @{n="deviceID"; e={$DeviceID}},* 			## DeviceID added to each Scheduled Task

		return $STList
	}

	[Object]DevicesAssetsGet([Int32]$DeviceID){
		$DataPath = ("/devices/{0}/assets" -f $DeviceID)
		$AssetList = $this.NCRestRequest($DataPath,"Get",$true,@{},$true) |
					Select-Object @{n="deviceID"; e={$DeviceID}},* 			## DeviceID added to Asset Info

		return $AssetList
	}


	[Object]StandardPsaGet(){
		$DataPath = "/standard-psa"
		return ($this.NCRestRequest($DataPath,"Get",$true))._links	## NoPaging/filter
	}


	[Object]ServiceOrgsGet(){
		$DataPath = "/service-orgs"
		return $this.NCRestRequest($DataPath,"Get",$true,@{},$true)
	}


	[Object]ServerInfoGet(){
		$DataPath = "/server-info"
		return $this.NCRestRequest($DataPath,"Get",$true)
	}

	[Object]ServerInfoExtraGet(){
		$DataPath = "/server-info/extra"
		return ($this.NCRestRequest($DataPath,"Get",$true)).data._extra
	}


	[Object]ScheduledTasksGet(){
		$DataPath = "/scheduled-tasks"
		return $this.NCRestRequest($DataPath,"Get",$true,@{},$true)
	}

	[Object]ScheduledTasksStatusGet([Int32]$TaskID){
		$DataPath = ("/scheduled-tasks/{0}/status" -f $TaskID)
		return $this.NCRestRequest($DataPath,"Get",$true)
	}

	[Object]ScheduledTasksStatusDetailGet([Int32]$TaskID){
		$DataPath = ("/scheduled-tasks/{0}/status/details" -f $TaskID)
		return $this.NCRestRequest($DataPath,"Get",$true)
	}


	[Object]CustomersGet(){
		$DataPath = "/customers"
		Return $this.NCRestRequest($DataPath,"Get",$true,@{},$true)
	}

	[Object]CustomersGet([Int32]$CustomerID){
		$DataPath = ("/customers/{0}" -f $CustomerID)
		Return $this.NCRestRequest($DataPath,"Get",$true)	## NoPaging/filter
	}


	[Object]CustomPsaGet(){
		$DataPath = "/custom-psa"
		return $this.NCRestRequest($DataPath,"Get",$true)	## NoPaging/filter
	}

	[Object]CustomPsaTicketsGet(){
		$DataPath = "/custom-psa/tickets"
		return $this.NCRestRequest($DataPath,"Get",$true,@{},$true)
	}


	[Object]UsersGet(){
		$DataPath = "/users"
		return $this.NCRestRequest($DataPath,"Get",$true,@{},$true)
	}


	[Object]SitesGet(){
		$DataPath = "/sites"
		Return $this.NCRestRequest($DataPath,"Get",$true,@{},$true)
	}

	[Object]SitesGet([Int32]$SiteID){
		$DataPath = ("/sites/{0}" -f $SiteID)
		Return $this.NCRestRequest($DataPath,"Get",$true)	## NoPaging/filter
	}

	[Object]SitesRegistrationTokenGet([Int32]$SiteID){
		$DataPath = ("/sites/{0}/registration-token" -f $SiteID)
		Return $this.NCRestRequest($DataPath,"Get",$true)	## NoPaging/filter
	}


	[Object]HealthGet(){
		$DataPath = "/health"
		Return $this.NCRestRequest($DataPath,"Get",$true)	## NoPaging/filter
	}


	[Object]DeviceFiltersGet(){
		$DataPath = "/device-filters"
		$Body = @{}
		$Body.viewScope = "OWN_AND_USED"

		Return $this.NCRestRequest($DataPath,"Get",$true,$Body,$true)
	}


	[Object]ApplianceTasksGet([Int32]$TaskID){
		$DataPath = ("/appliance-tasks/{0}" -f $TaskID)
		Return $this.NCRestRequest($DataPath,"Get",$true)	## NoPaging/filter
	}


	[Object]AccessGroupsGet(){
		$DataPath = "/access-groups"
		Return $this.NCRestRequest($DataPath,"Get",$true,@{},$true)
	}

	[Object]AccessGroupsGet([Int32]$GroupID){
		$DataPath = ("/access-groups/{0}" -f $GroupID)
		Return $this.NCRestRequest($DataPath,"Get",$true)	## NoPaging/filter
	}


	#Endregion RestData

	#Region CustomerData - SOAP
	[Object]ActiveIssuesList([Int]$ParentID){
		# No SearchBy-string adds an empty String.
		return $this.ActiveIssuesList($ParentID,"",0)
	}
	
	[Object]ActiveIssuesList([Int]$ParentID,[String]$IssueSearchBy){
		# No SearchBy-string adds an empty String.
		return $this.ActiveIssuesList($ParentID,$IssueSearchBy,0)
	}

	[Object]ActiveIssuesList([Int]$ParentID,[String]$IssueSearchBy,[Int]$IssueStatus){
		## Refresh / Clean KeyPair-container.
		$this.KeyPairs = @()

		## Add parameters as KeyPairs.
		$KeyPair1 = [PSObject]@{Key='customerID'; Value=$ParentID;}
		$this.KeyPairs += $KeyPair1

		## Optional keypair(s) for activeIssuesList. ToDo: Create ENums for choices.

		## SearchBy
		## A string-value to search the: so, site, device, deviceClass, service, transitionTime,
		## notification, features, deviceID, and ip address.
		If ($IssueSearchBy){
			$KeyPair2 = [PSObject]@{Key='searchBy'; Value=$IssueSearchBy;}
			$this.KeyPairs += $KeyPair2
		}
		
		## OrderBy
		## Valid inputs are: customername, devicename, servicename, status, transitiontime,numberofacknoledgednotification,
		## 					serviceorganization, deviceclass, licensemode, and endpointsecurity.
		## Default is customername.
#		$IssueOrderBy = "transitiontime"
#		$KeyPair3 = [PSObject]@{Key='orderBy'; Value=$IssueOrderBy;}
#		$this.KeyPairs += $KeyPair3

		## ReverseOrder
		## Must be true or false. Default is false.
#		$IssueOrderReverse = "true"
#		$KeyPair4 = [PSObject]@{Key='reverseorder'; Value=$IssueOrderReverse;}
#		$this.KeyPairs += $KeyPair4

		## Status
		## Only 1 (last) statusfilter will be applied (if multiple are used in the API).

		$IssueStatusFilter=''
		$IssueAcknowledged = ''
	
		## Valid inputs are: failed, stale, normal, warning, no data, misconfigured, disconnected
		If($IssueStatus -in (1..7)){
			$IssueStatusFilter=($this.NCStatus.$IssueStatus).ToLower()
		}

		## Valid inputs are: "Acknowledged" or "Unacknowledged"
		If($IssueStatus -in (11,12)){
			$IssueAcknowledged = $this.NCStatus.$IssueStatus
		}


		## NOC_View_Status_Filter		Reflected in NotifState
		## Valid inputs are: failed, stale, normal, warning, no data, misconfigured, disconnected
		## 'normal' does not return any data.
		If ($IssueStatusFilter){
			$KeyPair5 = [PSObject]@{Key='NOC_View_Status_Filter'; Value=$IssueStatusFilter;}
			$this.KeyPairs += $KeyPair5
		}

		## NOC_View_Notification_Acknowledgement_Filter. Reflected in numberofactivenotification, numberofacknowledgednotification
		## Valid inputs are: "Acknowledged" or "Unacknowledged"
		If ($IssueAcknowledged){
			$KeyPair6 = [PSObject]@{Key='NOC_View_Notification_Acknowledgement_Filter'; Value=$IssueAcknowledged;}
			$this.KeyPairs += $KeyPair6
		}

		$this.rc = $null

		## KeyPairs is mandatory in this query. returns limited list
		Try{
#			$this.rc = $this.Connection.activeIssuesList($this.PlainUser(), $this.PlainPass(), $this.KeyPairs)
			$this.rc = $this.GetNCData('activeIssuesList', $this.KeyPairs)
		}
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}

		## Needs 'issue' iso 'items' for ReturnObjects
#		Return $this.ProcessData1($this.rc, "issue")
		Return $this.ProcessData1($this.rc)
	}

	[Object]JobStatusList([Int]$ParentID){
		## Uses CustomerID. Reports ONLY Scripting-tasks now (not AMP or discovery).

		## Refresh / Clean KeyPair-container.
		$this.KeyPairs = @()

		## Add parameters as KeyPairs.
		$KeyPair1 = [PSObject]@{Key='customerID'; Value=$ParentID;}
		$this.KeyPairs += $KeyPair1

		$this.rc = $null

		Try{
#			$this.rc = $this.Connection.jobStatusList($this.PlainUser(), $this.PlainPass(), $this.KeyPairs)
			$this.rc = $this.GetNCData('jobStatusList', $this.KeyPairs)
		}
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}

		Return $this.ProcessData1($this.rc)
	}
	
	[Object]CustomerList(){
	
		Return $this.CustomerList($false)
	}
	
	[Object]CustomerList([Boolean]$SOList){
		## Refresh / Clean KeyPair-container.
		$this.KeyPairs = @()

		If($SOList){
			$KeyPair1 = [PSObject]@{Key='listSOs'; Value='true';}
			$this.KeyPairs += $KeyPair1
		}

		$this.rc = $null

		## KeyPairs Array must exist, but is not used in this query.
		Try{
#			$this.rc = $this.Connection.customerList($this.PlainUser(), $this.PlainPass(), $this.KeyPairs)
			$this.rc = $this.GetNCData('customerList', $this.KeyPairs)
		}
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}

#		Return $this.ProcessData1($this.rc, "items")
		Return $this.ProcessData1($this.rc)
	}

	[Object]CustomerListChildren([Int]$ParentID){
		## Refresh / Clean KeyPair-container.
		$this.KeyPairs = @()

		## Add parameters as KeyPairs.
		$KeyPair1 = [PSObject]@{Key='customerID'; Value=$ParentID;}
		$this.KeyPairs += $KeyPair1

		$this.rc = $null

		## KeyPairs is mandatory in this query. returns limited list
		Try{
#			$this.rc = $this.Connection.customerListChildren($this.PlainUser(), $this.PlainPass(), $this.KeyPairs)
			$this.rc = $this.GetNCData('customerListChildren', $this.KeyPairs)
		}
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}

#		Return $this.ProcessData1($this.rc, "items")
		Return $this.ProcessData1($this.rc)
	}

	[Object]CustomerPropertyValue([Int]$CustomerID,[String]$PropertyName){

		## Data-caching for faster future-access / lookup.
		If(!$this.CustomerData -Or $this.CustomerDataModified){
			#$this.CustomerData = $this.customerlist() | Select-Object customerid,customername,parentid
			$this.CustomerData = $this.customerlist() | Select-Object customerid,customername,parentid,* -ErrorAction SilentlyContinue
		}

		## Retrieve value from cache
		$Returndata = ($this.CustomerData).where({ $_.customerID -eq $CustomerID }).$PropertyName

		Return $ReturnData

	}

	[Int]CustomerAdd($CustomerDetails){
		Return $this.CustomerAdd($CustomerDetails.CustomerName,$CustomerDetails.ParentID,$CustomerDetails)
	}

	[Int]CustomerAdd([String]$CustomerName,[Int]$ParentID){
		Return $this.CustomerAdd($CustomerName,$ParentID,@{})
	}

	[Int]CustomerAdd([String]$CustomerName,[Int]$ParentID,$CustomerDetails){

		## Refresh / Clean KeyPair-container.
		$this.KeyPairs = @()

		If ($CustomerName){
			$KeyPair1 = [PSObject]@{Key='customername'; Value=$CustomerName;}
			$this.KeyPairs += $KeyPair1
		}
		Else{
			Write-host "Mandatory field customername not specified"
			Exit
		}

		If ($ParentID){
			$KeyPair2 = [PSObject]@{Key='parentid'; Value=$ParentID;}
			$this.KeyPairs += $KeyPair2
		}
		Else{
			Write-host "Mandatory field parentid not specified"
			Exit
		}

		## Only basic properties are allowed during addition, others are skipped. Must be an ordered-/hash-list.
		# Check/build list of Basic properties first (Should be set at connect).
		if (!$this.CustomerValidation){
			$this.CustomerValidation = ($this.customerlist($true) | get-member | where-object {$_.membertype -eq "noteproperty"} ).name
		}

		# Create KeyValue-pairs for basic properties only.
		If($CustomerDetails){
			If ($CustomerDetails -is [System.Collections.IDictionary]){
				# Remove Mandatory fields from validationlist. Already in the keypairs.
				$CustomerAttributes = $this.uservalidation | Where-Object {$_ -notin @("customername","parentid")}

				# Add all validating keys.
				ForEach($key in $CustomerDetails.keys){
					If ($CustomerAttributes -contains $key){
						## This is a standard CustomerProperty.
						#Write-host ("Adding {1} to {0}." -f $key, $CustomerDetails[$key])
						$KeyPair = [PSObject]@{Key=$key; Value=$CustomerDetails[$key];}
						$this.KeyPairs += $KeyPair
					}	
				}
			}Else{
				Write-Host "The customer-details must be given in a Hash or Ordered list."
			}
		}

		$this.rc = $null
		Try{
			## Default GetNCData can be used for API-request
			$this.rc = $this.GetNCData('customerAdd', $this.KeyPairs)
		}
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}

		## Clear current CustomerList-cache
		$this.CustomerData = $null

		## No dataprocessing needed. Return New customerID
		Return $this.rc[0]
	}

	[void]CustomerModify([Int]$CustomerID,[String]$PropertyName,[String]$PropertyValue){
		## Basic Customer-properties in KeyPairs

		if (!$this.CustomerValidation){
			$this.CustomerValidation = ($this.customerlist($true) | get-member | where-object {$_.membertype -eq "noteproperty"} ).name
		}

		## Validate $PropertyName
		If(!($this.CustomerValidation -contains $PropertyName)){
			Write-Host "Invalid customer field: $PropertyName."
			Break
		}

		#Mandatory (Key) customerid - (Value) the (customer) id of the ID of the existing service organization/customer/site being modified.
		#Mandatory (Key) customername - (Value) Desired name for the new customer or site. Maximum of 120 characters.
		#Mandatory (Key) parentid - (Value) the (customer) id of the parent service organization or parent customer for the new customer/site.
		
		## Lookup Data from cache for mandatory fields related to the $CustomerID.
		$CustomerName = $this.CustomerPropertyValue($CustomerID,"CustomerName")
		$ParentID = $this.CustomerPropertyValue($CustomerID,"ParentID")

		## For an Invalid CustomerID, No additional lookup-data is found.
		If(!$ParentID){
			Write-Host "Unknown CustomerID: $CustomerID."
			Break
		}

		## Refresh / Clean KeyPair-container.
		$this.KeyPairs = @()

		## Add Mandatory parameters as KeyPairs.
		$KeyPair1 = [PSObject]@{Key='customerid'; Value=$CustomerID;}
		$this.KeyPairs += $KeyPair1
		
		$KeyPair2 = [PSObject]@{Key="customername"; Value=$CustomerName;}
		$this.KeyPairs += $KeyPair2
		
		$KeyPair3 = [PSObject]@{Key="parentid"; Value=$ParentID;}
		$this.KeyPairs += $KeyPair3

		## PropertyName already validated at CmdLet.
		$KeyPair4 = [PSObject]@{Key=$PropertyName; Value=$PropertyValue;}
		$this.KeyPairs += $KeyPair4

		## Using as [void]: No returndata needed/used.
		Try{
#			$this.Connection.CustomerModify($this.PlainUser(), $this.PlainPass(), $this.KeyPairs)
			## Standard GetNCData can be used here.
			$this.GetNCData('customerModify', $this.KeyPairs)
        }
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}

		## CustomerData-cache rebuild initiation.
		$this.CustomerDataModified = $true

	}

	[Object]OrganizationPropertyList(){
		# No FilterArray-parameter adds an empty ParentIDs-Array. Returns all customers
		return $this.OrganizationPropertyList(@())
	}
	
	[Object]OrganizationPropertyList([Array]$ParentIDs){
		# Returns all Custom Customer-Properties and values.

		$this.rc = $null
		Try{
#			$this.rc = $this.Connection.organizationPropertyList($this.PlainUser(), $this.PlainPass(), $ParentIDs, $false)
			$this.rc = $this.GetNCDataOP('organizationPropertyList', $ParentIDs, $false)
        }
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}

		Return $this.ProcessData1($this.rc, "properties",$false)
	}

	[Int]OrganizationPropertyID([Int]$OrganizationID,[String]$PropertyName){
		## Search the DevicePropertyID by Name/label (Case InSensitive).
		## Returns 0 (zero) if not found.
		$OrganizationPropertyID = 0
		
		$this.rc = $null
		$OrganizationProperties = $null
		Try{
			## Retrieve a list of the properties for the given OrganizationID
#			$OrganizationProperties = $this.Connection.OrganizationPropertyList($this.PlainUser(), $this.PlainPass(), $OrganizationID, $false)
			$OrganizationProperties = $this.GetNCDataOP('organizationPropertyList', $OrganizationID, $false)
#			$OrganizationProperties = $this.OrganizationPropertyList($OrganizationID)
		}
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}
	
		ForEach ($OrganizationProperty in $OrganizationProperties.properties){
			## Case InSensitive compare.
			If($OrganizationProperty.label -eq $PropertyName){
				$OrganizationPropertyID = $OrganizationProperty.PropertyID
			}
		}		
		
		Return $OrganizationPropertyID
	}

	[void]OrganizationPropertyModify($OrganizationPropertyObject){
		[void]$this.OrganizationPropertyModify($OrganizationPropertyObject.customerid,$OrganizationPropertyObject.name,$OrganizationPropertyObject.value)
	}

	[void]OrganizationPropertyModify([Int]$OrganizationID,[String]$OrganizationPropertyName,[String]$OrganizationPropertyValue){
	
		## Find the propertID by name first.
		[Int]$OrganizationPropertyID = $this.OrganizationPropertyID($OrganizationID,$OrganizationPropertyName)
		If ($OrganizationPropertyID -gt 0){
			[void]$this.OrganizationPropertyModify($OrganizationID,$OrganizationPropertyID,$OrganizationPropertyValue)
		}
		Else{
			## Throw Error
			Write-Host "OrganizationProperty '$OrganizationPropertyName' not found on this Customer."
			Break
		}
	}		
		
	[void]OrganizationPropertyModify([Int]$OrganizationID,[Int]$OrganizationPropertyID,[String]$OrganizationPropertyValue){

		#$OrganizationProperty = [PSObject]@{PropertyID=$OrganizationPropertyID; value=$OrganizationPropertyValue; PropertyIDSpecified='True';}
#		$Organization = [PSObject]@{OrganizationID=$OrganizationID; properties=$OrganizationProperty; OrganizationIDSpecified='True';}
		#$OrganizationPropertyArray = [PSObject]@{CustomerID=$OrganizationID; properties=$OrganizationProperty; CustomerIDSpecified='True';}
		
	
		## Organization-layout:
		# $Organization = [PSObject]@{CustomerID=''; properties=''; CustomerIDSpecified='True';}
		# $Organization = New-Object -TypeName ($this.NameSpace + '.organizationProperties')
		## properties hold an array of DeviceProperties

		## Individual OrganizationProperty layout:
		# $OrganizationProperty = [PSObject]@{PropertyID=''; value=''; PropertyIDSpecified='True';}
		# $OrganizationProperty = New-Object -TypeName ($this.NameSpace + '.organizationProperty')

#        If ($OrganizationPropertyArray){
	        Try{
#				$this.Connection.OrganizationPropertyModify($this.PlainUser(), $this.PlainPass(), $OrganizationPropertyArray)
				$this.SetNCDataOP('organizationPropertyModify',$OrganizationID,$OrganizationPropertyID,$OrganizationPropertyValue)
			}
			Catch {
				$this.Error = $_
				$this.ErrorHandler()
			}
#        }
#        Else{
#			Write-Host "INFO:OrganizationPropertyModify - Nothing to save"
#        }
		
	}
	
	#EndRegion CustomerData - SOAP

	#Region DeviceData - SOAP
	[Object]DeviceList([Int]$ParentID){
		## Use default Settings for DeviceList
		Return $this.Devicelist($ParentID,$true,$false)
	}
	
	[Object]DeviceList([Int]$ParentID,[Bool]$Devices,[Bool]$Probes){
		## Returns only Managed/Imported Items.

		## Refresh / Clean KeyPair-container.
		$this.KeyPairs = @()

		## Add parameters as KeyPairs. Need to be unique Objects.
		$KeyPair1 = [PSObject]@{Key='customerID'; Value=$ParentID;}
		$this.KeyPairs += $KeyPair1

		$KeyPair2 = [PSObject]@{Key='devices'; Value=$Devices;}
		$this.KeyPairs += $KeyPair2

		$KeyPair3 = [PSObject]@{Key='probes'; Value=$Probes;}
		$this.KeyPairs += $KeyPair3

		$this.rc = $null
		Try{
#			$this.rc = $this.Connection.deviceList($this.PlainUser(), $this.PlainPass(), $this.KeyPairs)
			$this.rc = $this.GetNCData('deviceList', $this.KeyPairs)
		}
		Catch{
			$this.Error = $_
			$this.ErrorHandler()
		}
		
#		Return $this.ProcessData1($this.rc, "info")
		Return $this.ProcessData1($this.rc)
	}

	[Object]DeviceGet([Array]$DeviceIDs){
		Return $this.DeviceGet($DeviceIDs,$false)
	}

	[Object]DeviceGet([Array]$DeviceIDs,[Bool]$ShowProgress){
			## Refresh / Clean KeyPair-container.
		
		$this.KeyPairs = @()
		foreach($DeviceID in $deviceIDs){
			## Add multiple IDs as KeyPairs.
			#Write-Host "Adding key for $DeviceID"
			$KeyPair1 = [PSObject]@{Key='deviceID'; Value=$DeviceID;}
			$this.KeyPairs += $KeyPair1
		}

		If($ShowProgress){
			Write-Progress -Activity ("Retrieving object data from {0}." -f $this.ConnectionURL)
			#Start-Sleep -Milliseconds 500
		}

		$this.rc = $null
		Try{
#			$this.rc = $this.Connection.deviceGet($this.PlainUser(), $this.PlainPass(), $this.KeyPairs)
			$this.rc = $this.GetNCData('deviceGet', $this.KeyPairs)
		}
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}
		
		Return $this.ProcessData1($this.rc,$ShowProgress)
	}

	[Object]DeviceGetAppliance([int]$ApplianceID){
		## Refresh / Clean KeyPair-container.
		$this.KeyPairs = @()

		## Add parameter as KeyPair.
		$KeyPair1 = [PSObject]@{Key='applianceID'; Value=$ApplianceID;}
		$this.KeyPairs += $KeyPair1

		$this.rc = $null
		Try{
#			$this.rc = $this.Connection.deviceGet($this.PlainUser(), $this.PlainPass(), $this.KeyPairs)
			$this.rc = $this.GetNCData('deviceGet', $this.KeyPairs)
		}
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}
		
		Return $this.ProcessData1($this.rc)
	}
		
	[Object]DeviceGetStatus([Int]$DeviceID){
		## Refresh / Clean KeyPair-container.
		$this.KeyPairs = @()

		## Add parameters as KeyPairs.
		$KeyPair1 = [PSObject]@{Key='deviceID'; Value=$DeviceID;}
		$this.KeyPairs += $KeyPair1

		$this.rc = $null
		Try{
#			$this.rc = $this.Connection.deviceGetStatus($this.PlainUser(), $this.PlainPass(), $this.KeyPairs)
			$this.rc = $this.GetNCData('deviceGetStatus', $this.KeyPairs)
		}
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}
		
#		Return $this.ProcessData1($this.rc, "info")
		Return $this.ProcessData1($this.rc)
	}

	[Object]DevicePropertyList([Array]$DeviceIDs,[Array]$DeviceNames,[Array]$FilterIDs,[Array]$FilterNames){
		Return $this.DevicePropertyList($DeviceIDs,$DeviceNames,$FilterIDs,$FilterNames,$false)
	}

	[Object]DevicePropertyList([Array]$DeviceIDs,[Array]$DeviceNames,[Array]$FilterIDs,[Array]$FilterNames,[Bool]$ShowProgress){
		## Reports the Custom Device-Properties and values. Uses filter-arrays.
		## Names are Case-sensitive.
		## Returns both Managed and UnManaged Devices.

		If($ShowProgress){
			Write-Progress -Activity ("Retrieving object data from {0}." -f $this.ConnectionURL)
			#Start-Sleep -Milliseconds 500
		}

		$this.rc = $null

		Try{
#			$this.rc = $this.Connection.devicePropertyList($this.PlainUser(), $this.PlainPass(), $DeviceIDs,$DeviceNames,$FilterIDs,$FilterNames,$false)
			$this.rc = $this.GetNCDataDP('devicePropertyList',$DeviceIDs,$DeviceNames,$FilterIDs,$FilterNames,$false)
		}
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}

		Return $this.ProcessData1($this.rc, "properties", $ShowProgress)
		#Return $this.rc
	}

	[Int]DevicePropertyID([Int]$DeviceID,[String]$PropertyName){
		## Search the DevicePropertyID with Name-Filter (Case InSensitive).
		## Returns 0 (zero) if not found.
		$DevicePropertyID = 0
		
		$DeviceProperties = $null
		Try{
#			$DeviceProperties = $this.Connection.devicePropertyList($this.PlainUser(), $this.PlainPass(), $DeviceID,$null,$null,$null,$false)
			$DeviceProperties = $this.GetNCDataDP('devicePropertyList',$DeviceID,$null,$null,$null,$false)
		}
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}
	
		ForEach ($DeviceProperty in $DeviceProperties.properties){
			## Case InSensitive compare.
			If($DeviceProperty.label -eq $PropertyName){
				$DevicePropertyID = $DeviceProperty.devicePropertyID
			}
		}		
		
		Return $DevicePropertyID
	}

	[void]DevicePropertyModify($DevicePropertyObject){
		[void]$this.DevicePropertyModify($DevicePropertyObject.deviceid,$DevicePropertyObject.name,$DevicePropertyObject.value)
	}

	[void]DevicePropertyModify([Int]$DeviceID,[String]$DevicePropertyName,[String]$DevicePropertyValue){
	
		[Int]$DevicePropertyID = $this.DevicePropertyID($DeviceID,$DevicePropertyName)
		If ($DevicePropertyID -gt 0){
			[void]$this.DevicePropertyModify($DeviceID,$DevicePropertyID,$DevicePropertyValue)
		}
		Else{
			## Throw Error
			Write-Host "DeviceProperty '$DevicePropertyName' not found on this Device."
			Break
#			$this.Error = "DeviceProperty '$DevicePropertyName' not found on this Device."
#			$this.ErrorHandler()
		}

	}

	[void]DevicePropertyModify([Int]$DeviceID,[Int]$DevicePropertyID,[String]$DevicePropertyValue){

		## Create a custom DevicePropertyArray. Details below.
#		$DeviceProperty = [PSObject]@{devicePropertyID=$DevicePropertyID; value=$DevicePropertyValue; devicePropertyIDSpecified='True';}
#		$DevicesPropertyArray = [PSObject]@{deviceID=$DeviceID; properties=$DeviceProperty; deviceIDSpecified='True';}
		
	
		## Device-layout for WebProxy:
		# $Device = [PSObject]@{deviceID=''; properties=''; deviceIDSpecified='True';}
		# $Device = New-Object -TypeName ($this.NameSpace + '.deviceProperties')
		## properties hold an array of DeviceProperties

		## Individual DeviceProperty layout for WebProxy:
		# $DeviceProperty = [PSObject]@{devicePropertyID=''; value=''; devicePropertyIDSpecified='True';}
		# $DeviceProperty = New-Object -TypeName ($this.NameSpace + '.deviceProperty')

#        If ($devicesPropertyArray){
#	        Try{
#                $this.Connection.devicePropertyModify($this.PlainUser(), $this.PlainPass(), $devicesPropertyArray)
				$this.SetNCDataDP('devicePropertyModify',$DeviceID,$DevicePropertyID,$DevicePropertyValue)
#			}
#			Catch {
#				$this.Error = $_
#				$this.ErrorHandler()
#			}
#        }
#        Else{
#			Write-Host "INFO:DevicePropertyModify - Nothing to save"
#        }		
	}

	[Object]DeviceAssetInfoExportDevice(){
		## Reports all details for Monitored Assets.
		## !!! Potentially puts a high load on the NCentral-server!!!
		## Removed/disabled in this Module.		--> Better api/method exists.
		## Only supporting 'DeviceAssetInfoExportDeviceWithSetting' for a single deviceID.
		
#		## Class: DeviceData
#		##   deviceAssetInfoExport						Deprecated
#		##	 deviceAssetInfoExportDevice				Same as 'WithSettings' without specifying filters.
#		##	 deviceAssetInfoExportDeviceWithSettings	Implemented as a separate method
#		##
#		## Reports all Monitored Assets and Details. No filtering by CustomerID or DeviceID. Reports All Assets.
#		## Use without Header-formatting (has sub-headers). Device.customerid=siteid.
#		## Generating this list takes quite a long time. Might even time-out.
#		#$rc = $nws.deviceAssetInfoExport2("0.0", $username, $password)		#Error - nonexisting
#		#$ri = $nws.deviceAssetInfoExport("0.0", $username, $password)		#Error - unsupported version
#		#$ri = $nws.deviceAssetInfoExportDevice("0.0", $username, $password)
#		#$PairClass="info"

		$this.rc = $null
	
		Try{
#			$this.rc = $this.Connection.deviceAssetInfoExportDevice("0.0", $this.PlainUser(), $this.PlainPass())	## deprecated
#			$this.rc = $this.GetNCData('deviceAssetInfoExportDevice','',"0.0")										## Disabled on purpose
			
        }
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}
		
		Return $this.rc
#		Return $this.ProcessData1($this.rc, "info")
	}

	[Object]DeviceAssetInfoExportDeviceWithSettings([Array]$DeviceIDs){
		## Reports Monitored Assets.
		## Calls Full Command with Parameters
		Return $this.DeviceAssetInfoExportDeviceWithSettings($DeviceIds,$null,$null,$null,$null,$null,$false)
	}

	[Object]DeviceAssetInfoExportDeviceWithSettings([Array]$DeviceIDs,[Array]$DeviceNames,[Array]$FilterIDs,[Array]$FilterNames,[Array]$Inclusions,[Array]$Exclusions,[Boolean]$ShowProgress){
		## Reports Monitored Assets.
		## Currently returns all categories for the selected devices. TODO: category-filtering. 

#		From Documentation:
#		http://mothership.n-able.com/dms/javadoc_ei2/com/nable/nobj/ei2/ServerEI2_PortType.html
#
#		Use only ONE of the following options to limit information to certain devices 	 
#		"TargetByDeviceID" - value for this key is an array of deviceids 	 
#		"TargetByDeviceName" - value for this key is an array of devicenames 	 
#		"TargetByFilterID" - value for this key is an array of filterids 	 
#		"TargetByFilterName" - value for this key is an array filternames 	 

		$this.KeyPairs = @()

		$KeyPair1 = $null
		## Add only one of the parameters as KeyPair. by priority.
		If ($DeviceIDs){
			$KeyPair1 = [PSObject]@{Key='TargetByDeviceID'; Value=$DeviceIDs;}
#			ForEach($DeviceID in $DeviceIDs){
#				$KeyPair1 = [PSObject]@{Key='TargetByDeviceID'; Value=$DeviceID;}
#				$this.KeyPairs += $KeyPair1
#			}

		}ElseIf($FilterIDs){
			$KeyPair1 = [PSObject]@{Key='TargetByFilterID'; Value=$FilterIDs;}
		}ElseIF($DeviceNames){
			$KeyPair1 = [PSObject]@{Key='TargetByDeviceName'; Value=$DeviceNames;}
		}ElseIf($FilterNames){
			$KeyPair1 = [PSObject]@{Key='TargetByFilterName'; Value=$FilterNames;}
		}

		## Do not continue if no filter is specified.
		## Introduced due to potential heavy server load.
		If (!$KeyPair1){
			## TODO: Throw Error
			Break
		}
		$this.KeyPairs += $KeyPair1

#		## Without Inclusion/Exclusion ALL categories will be returned.
#		## Documentation On Inclusion/Exclusion:
#		## Key = "InformationCategoriesInclusion" and Value = String[] {"asset.device", "asset.os"} then only information for these two categories will be returned. 	 
#		## Key = "InformationCategoriesExclusion" and Value = String[] {"asset.device", "asset.os"}
#		## Work in Progress
#
#		## Use an ArrayList to allow addition or removal. Using [void] to suppress response (same as | $null at the end).
#		[System.collections.ArrayList]$RequestFilter = @()
#		[void]$RequestFilter.add("asset.application")
#		[void]$RequestFilter.add("asset.device")					# Always included (Root-item)
#		[void]$RequestFilter.add("asset.device.ncentralassettag")
#		[void]$RequestFilter.add("asset.logicaldevice")
#		[void]$RequestFilter.add("asset.mappeddrive")
#		[void]$RequestFilter.add("asset.mediaaccessdevice")
#		[void]$RequestFilter.add("asset.memory")
#		[void]$RequestFilter.add("asset.networkadapter")
#		[void]$RequestFilter.add("asset.os")
#		[void]$RequestFilter.add("asset.osfeatures")
#		[void]$RequestFilter.add("asset.patch")
#		[void]$RequestFilter.add("asset.physicaldrive")
#		[void]$RequestFilter.add("asset.port")
#		[void]$RequestFilter.add("asset.printer")
#		[void]$RequestFilter.add("asset.raidcontroller")
#		[void]$RequestFilter.add("asset.service")
#		[void]$RequestFilter.add("asset.socustomer")
#		[void]$RequestFilter.add("asset.usbdevice")
#		[void]$RequestFilter.add("asset.videocontroller")
#

		## [ToDo] Category-filtering does not seem to be working as documented
		$KeyPair2 = $null

		## inclusion prevails
		If ($Inclusions){
			$this.RequestFilter.clear()
			ForEach($inclusion in $Inclusions.ToLower()){
				## Allow for categorynames without prefix.
				If(($inclusion.split("."))[0] -like "asset"){
					## Prefix already present.
					[void]$this.RequestFilter.add($inclusion)
				}
				Else{
					## Add with Prefix
					[void]$this.RequestFilter.add("asset.{0}" -f $inclusion)
				}
			}
			$KeyPair2 = [PSObject]@{Key="InformationCategoriesInclusion"; Value=([Array]$this.RequestFilter);}
		}
		ElseIf ($Exclusions) {
			$this.RequestFilter.clear()
			ForEach($exclusion in $Exclusions.ToLower()){
				## Allow for categorynames without prefix.
				If(($exclusion.split("."))[0] -like "asset"){
					## Prefix already present.
					[void]$this.RequestFilter.add($exclusion)
				}
				Else{
					## Add with Prefix
					[void]$this.RequestFilter.add("asset.{0}" -f $exclusion)
				}
			}
			$KeyPair2 = [PSObject]@{Key="InformationCategoriesExclusion"; Value=([Array]$this.RequestFilter);}
		}

		If ($KeyPair2){
			$this.KeyPairs += $KeyPair2
		}

		If($ShowProgress){
			Write-Progress -Activity ("Retrieving object data from {0}." -f $this.ConnectionURL)
			#Start-Sleep -Milliseconds 500
		}

		$this.rc = $null
		
		Try{
			#$this.rc = $this.Connection.deviceAssetInfoExportDeviceWithSettings("0.0", $this.PlainUser(), $this.PlainPass(), $this.KeyPairs)
			#$this.rc = $this.Connection.deviceAssetInfoExport2("0.0", $this.PlainUser(), $this.PlainPass(), $this.KeyPairs)
			$this.rc = $this.GetNCData('deviceAssetInfoExportDeviceWithSettings',$this.KeyPairs,"0.0")

		}
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}
		
		## Todo: Parameter for what to return:
		##		Flat Object (ProcessData1) or 
		##		Multi-Dimensional Object (ProcessData2).
#		Return $this.ProcessData2($this.rc, "info")
		Return $this.ProcessData2($this.rc, $ShowProgress)
	}

	#EndRegion DeviceData - SOAP

	#Region NCentralAppData - SOAP
		
#	## To Do
#	## TODO - User/Role/AccessGroup as user-object.
#	## TODO - Filter/Rule list (Not available through API yet)
#	## TODO – Auditing information (Not available through API yet)

	
	[Object]AccessGroupList([Int]$ParentID){
		## List All Access Groups
		## Mandatory valid CustomerID (SO/Customer/Site-level), does not seem to use it. 

		## Refresh / Clean KeyPair-container.
		$this.KeyPairs = @()

		## Add parameters as KeyPairs.
		$KeyPair1 = [PSObject]@{Key='customerID'; Value=$ParentID;}
		$this.KeyPairs += $KeyPair1

		$this.rc = $null

		Try{
#			$this.rc = $this.Connection.accessGroupList($this.PlainUser(), $this.PlainPass(), $this.KeyPairs)
			$this.rc = $this.GetNCData('accessGroupList', $this.KeyPairs)
		}
		Catch {
			#$this.ErrorHandler($_)
			$this.Error = $_
			$this.ErrorHandler()
		}
		Return $this.ProcessData1($this.rc)
		#Return $this.ProcessData1($this.rc.where{$_.customerid -eq $parentID})

	}

	[Object]AccessGroupGet([Int]$GroupID){
		## Defaults to CustomerGroup
		Return $this.AccessGroupGet($GroupID,$null,$true)
	}

	[Object]AccessGroupGet([Int]$GroupID,[Boolean]$IsCustomerGroup){
		Return $this.AccessGroupGet($GroupID,$null,$IsCustomerGroup)
	}

	[Object]AccessGroupGet([Int]$GroupID,[Int]$ParentID,[Boolean]$IsCustomerGroup){
		## List Access Groups details.
		## Uses groupID and customerGroup. Gets details for the specified AccessGroup.
		## Mandatory parameters:
		## 		-GroupID		Error: '1012 Mandatory settings not present'
		##		-CustomerGroup	Error: '4100 Invalid parameters'
		##						Must be in Sync with GroupType
		## The ParentID/customerID seems unused.

		If ($null -eq $IsCustomerGroup){
			$IsCustomerGroup = $true
		}

		## Refresh / Clean KeyPair-container.
		$this.KeyPairs = @()

		## Add parameters as KeyPairs.
		$KeyPair1 = [PSObject]@{Key='groupID'; Value=$GroupID;}
		$this.KeyPairs += $KeyPair1

		if($ParentID){
			$KeyPair2 = [PSObject]@{Key='customerID'; Value=$ParentID;}
			$this.KeyPairs += $KeyPair2
		}

		$KeyPair3 = [PSObject]@{Key='customerGroup'; Value=$IsCustomerGroup;}
		$this.KeyPairs += $KeyPair3

		$this.rc = $null

		Try{
#			$this.rc = $this.Connection.accessGroupGet($this.PlainUser(), $this.PlainPass(), $this.KeyPairs)
			$this.rc = $this.GetNCData('accessGroupGet', $this.KeyPairs)
		}
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}
	
		Return $this.ProcessData1($this.rc)
	}

	[Int]UserAdd([HashTable]$UserDetails){
		Return $this.UserAdd($UserDetails.email,$UserDetails.customerID,$UserDetails.password,$UserDetails.firstname,$UserDetails.lastname,$UserDetails)
	}

	[Int]UserAdd([String]$UserEmail,[Int]$CustomerID,[String]$UserPassword,[String]$UserFirstName,[String]$UserLastName,[Hashtable]$UserDetails){

		## Refresh / Clean KeyPair-container.
		$this.KeyPairs = @()

		IF(!$UserEmail){
			Write-host "Mandatory field email not specified"
			Exit
		}
		$KeyPair1 = [PSObject]@{Key='email'; Value=$UserEmail;}
		$this.KeyPairs += $KeyPair1

		If(!$CustomerID){
			## Inserting default to be done in CmdLet
		#	If($this.DefaultCustomerID){
		#		$CustomerID = $this.DefaultCustomerID
		#		Write-host ("Default CustomerID {0} will be used." -f $CustomerID)
		#	}
		#	Else{
				Write-host "Mandatory field customerid not specified"
				Exit
		#	}
		}
		$KeyPair2 = [PSObject]@{Key='customerID'; Value=$CustomerID;}
		$this.KeyPairs += $KeyPair2

		IF(!$UserPassword){
			Write-host "Mandatory field password not specified"
			Exit
		}
		$KeyPair3 = [PSObject]@{Key='password'; Value=$UserPassword;}
		$this.KeyPairs += $KeyPair3

		If(!$UserFirstName){
			Write-host "Mandatory field firstname not specified"
			Exit
		}
		$KeyPair4 = [PSObject]@{Key='firstname'; Value=$UserFirstName;}
		$this.KeyPairs += $KeyPair4

		If (!$UserLastName){
			Write-host "Mandatory field lastname not specified"
			Exit
		}
		$KeyPair5 = [PSObject]@{Key='lastname'; Value=$UserLastName;}
		$this.KeyPairs += $KeyPair5

#<#
		## Only basic properties are allowed during addition, others are skipped. Must be an ordered-/hash-list.
		# Check/build list of Basic properties first (Should be set at connect).
		if (!$this.UserValidation){
			#Throw an error
			Write-Host "Uservalidation not set."
			Exit
		}

		# Create KeyValue-pairs for basic properties only.
		If($UserDetails){
			If ($UserDetails -is [System.Collections.IDictionary]){
				# Remove Mandatory fields from validationlist. Already in the keypairs.
				$UserAttributes = $this.uservalidation | Where-Object {$_ -notin @("email","customerID","password","firstname","lastname")}

				# Add all validating keys.
				ForEach($key in $UserDetails.keys){
					If ($UserAttributes -contains $key){
						## This is a valid UserProperty.
						#Write-host ("Adding {1} to {0}." -f $key, $UserDetails[$key])
						$KeyPair = [PSObject]@{Key=$key; Value=$UserDetails[$key];}
						$this.KeyPairs += $KeyPair
					}	
				}
			}Else{
				Write-Host "The user-details must be given in a Hash or Ordered list."
				Exit
			}
		}
#>
		$this.rc = $null
		Try{
			## Default GetNCData can be used for API-request
			$this.rc = $this.GetNCData('userAdd', $this.KeyPairs)
		}
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}

		## Clear current CustomerList-cache
		$this.CustomerData = $null

		## No dataprocessing needed. Return New customerID
		Return $this.rc[0]
	}

	[Object]UserRoleList([Int]$ParentID){
		## List All User Roles
		## Mandatory valid CustomerID (SO/Customer/Site-level), does not seem to use it. 

		## Refresh / Clean KeyPair-container.
		$this.KeyPairs = @()

		## Add parameters as KeyPairs.
		$KeyPair1 = [PSObject]@{Key='customerID'; Value=$ParentID;}
		$this.KeyPairs += $KeyPair1

		$this.rc = $null
		Try{
#			$this.rc = $this.Connection.userRoleList($this.PlainUser(), $this.PlainPass(), $this.KeyPairs)
			$this.rc = $this.GetNCData('userRoleList', $this.KeyPairs)
		}
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}

		Return $this.ProcessData1($this.rc)

	}

	[Object]UserRoleGet([Int]$UserRoleID){
		Return $this.UserRoleGet($UserRoleID,$null)
	}

	[Object]UserRoleGet([Int]$UserRoleID,[Int]$ParentID){
		## List User Role details.

		## Refresh / Clean KeyPair-container.
		$this.KeyPairs = @()

		## Add parameters as KeyPairs.
		$KeyPair1 = [PSObject]@{Key='userRoleID'; Value=$UserRoleID;}
		$this.KeyPairs += $KeyPair1

		If($ParentID){
			$KeyPair2 = [PSObject]@{Key='customerID'; Value=$ParentID;}
			$this.KeyPairs += $KeyPair2
		}
		
		$this.rc = $null

		Try{
#			$this.rc = $this.Connection.userRoleGet($this.PlainUser(), $this.PlainPass(), $this.KeyPairs)
			$this.rc = $this.GetNCData('userRoleGet', $this.KeyPairs)
		}
		Catch {
			$this.Error = $_
			$this.ErrorHandler()
		}
		
		Return $this.ProcessData1($this.rc)
	}

	#EndRegion NCentralAppData - SOAP

#EndRegion Methods
}
## Class-section Ends here


#Region Generic Functions

Function Convert-Base64 {
	<#
	.Synopsis
	Encode or Decode a string to or from Base64.
	
	.Description
	Encode or Decode a string to or from Base64.
	Use Unicode (UTF16) by default, UTF8 is optional.
	Protected against double-encoding.
	
	#>

	[CmdletBinding()]

	## $Data: Mandatory=false to create more descriptive error-message.
	Param(
		[Parameter(Mandatory=$false,	#Data String to process
               Position = 0,
			HelpMessage = 'Data String to process')]
		[String]$Data,

		[Parameter(Mandatory=$false,	#Decode the data passed (Default is to Encode)
			HelpMessage = 'Decode the data passed (Default is Encode')]
		[switch]$Decode,
	
		[Parameter(Mandatory=$false,	#Use UTF8 (Default is Unicode/UTF16)
			HelpMessage = 'Use UTF8 (Default is Unicode/UTF16')]
			[Alias("NoUnicode")]
		[switch]$UTF8
	)

	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
		If (!$Data){
			Write-Host ("No data specfied for {0}." -f $MyInvocation.MyCommand.Name)
			Break
		}
	}
	Process{
	}
	End{
		Return [String]$NCsession.convertbase64($Data,$Decode,$UTF8)
	}
}

Function Format-Properties {
	<#
	.Synopsis
	Unifies the properties for all Objects in a list.
	
	.Description
	Unifies the properties for all Objects in a list.
	Solves Get-Member, Format-Table and Export-Csv 
	issue for not showing all properties.
	
	#>

	[CmdletBinding()]

	## $ObjectArray: Mandatory=false to create more descriptive error-message.
	Param(
		[Parameter(Mandatory=$false,	#Array Containing PS-Objects with varying properties
               #ValueFromPipeline = $true,
               Position = 0,
			HelpMessage = 'Array Containing PS-Objects')]
		[Array]$ObjectArray
	)

	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
		If (!$ObjectArray){
			Write-Host ("No data specfied for {0}." -f $MyInvocation.MyCommand.Name)
			Break
		}
	}
	Process{
	}
	End{
		#Write-Output 
		$NCsession.FixProperties($ObjectArray)
	}

}

#EndRegion Generic Functions

#EndRegion - Classes and Generic Functions

#Region PowerShell CmdLets
#	## To Do
#	## TODO - Error-handling at CmdLet Level.
#	## TODO - Add Examples to in-line documentation.
#	## TODO - Additional CmdLets (CustomerAdd, UserAdd, DataExport, PSA, CustomerObject, ...) 
#	## 

#Region Module-support
Function New-NCentralConnection{
	<#
	.Synopsis
	Connect to the NCentral server.

	.Description
	Connect to the NCentral server.
	Https is always used, since the data itself is unencrypted.

	The returned connection-object allows to extract and manipulate 
	NCentral Data through methods of the NCentral_Connection Class.

	To show available Commands, type:
	Get-NCHelp

	.Parameter ServerFQDN
	Specify the Server DNS-name for this Connection.
	The server needs to have a valid certficate for HTTPS.

	.Parameter PSCredential
	PowerShell-Credential object containing Username and
	Password for N-Central access. No MFA.

	.Parameter JWT
	String Containing the JavaWebToken for N-Central access.

	.Parameter DefaultCustomerID
	Sets the default CustomerID for this instance.
	The CustomerID can be found in the customerlist.
	If not specified, the default will be set to the lowest ParentId in the customerlist.
	Known values:
		CustomerID   1	Root / System
		CustomerID  50 	First ServiceOrganization (local N-Central)
		CustomerID 1xx	Hosted N-Central

	.Example
	$PSUserCredential = Get-Credential -Message "Enter NCentral API-User credentials"
	New-NCentralConnection NCserver.domain.com $PSUserCredential


	.Example
	New-NCentralConnection -ServerFQDN <Server> -JWT <Java Web Token>

	Use the line above inside a script for a fully-automated connection.

	#>

	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false)][String]$ServerFQDN,
        [Parameter(Mandatory=$false)][PSCredential]$PSCredential,
		[Parameter(Mandatory=$false)][String]$JWT,
        [Parameter(Mandatory=$false)][Int]$DefaultCustomerID
	)

	Begin{
		## Check parameters

		## Clear the ServerFQDN if there is no . in it. Will create dialog.
		If ($ServerFQDN -notmatch "\.") {
			$ServerFQDN = $null
		}

	}
	Process{
		## Store the session in a global variable as the default connection.

		# Initiate the connection with the given information.
		# Prompts for additional information if needed.
		If ($ServerFQDN){
			If ($PSCredential){
				#Write-Host "Using Credentials"
				$Global:_NCSession = [NCentral_Connection]::New($ServerFQDN, $PSCredential)
			}
			Elseif($JWT){
				#Write-Host "Using JWT"
				$Global:_NCSession = [NCentral_Connection]::New($ServerFQDN, $JWT)
			}
			Else {
				$Global:_NCSession = [NCentral_Connection]::New($ServerFQDN)
			}
		}
		Else {
			$Global:_NCSession = [NCentral_Connection]::New()
		}

		## ToDo: Check for succesful connection.
		#Write-Host ("Connection to {0} is {1}." -f $Global:_NCSession.ConnectionURL,$Global:_NCSession.IsConnected)

		# Set the default CustomerID for this session.
		## Set to the minimum of 50 if not specified.
		## Modified by te parent-info in the customerlist if needed (for hosted versions).
		If(!$DefaultCustomerID){
			$DefaultCustomerID = 50
		}

		$Global:_NCSession.DefaultCustomerID = $DefaultCustomerID
	}
	End{
		## Return the initiated Class
		#Write-Output 
		$Global:_NCSession
	}
}

Function NcConnected{
	<#
	.Synopsis
	Checks or initiates the NCentral connection.
	
	.Description
	Checks or initiates the NCentral connection.
	Returns $true if a connection established.
	
	#>
		
	$NcConnected = $false
	
	If (!$Global:_NCSession){
#		Write-Host "No connection to NCentral Server found.`r`nUsing 'New-NCentralConnection' to connect."
		New-NCentralConnection
	}

	## Succesful connection?	
	If ($Global:_NCSession){
		$NcConnected = $true
	}
	Else{
		Write-Host "No valid connection to NCentral Server."
	}
	
	Return $NcConnected
}
	
Function Get-NCHelp{
	<#
	.Synopsis
	Shows a list of available PS-NCentral commands and the synopsis.

	.Description
	Shows a list of available PS-NCentral commands and the synopsis.

	#>

	Get-Command -Module PS-NCentral | 
	#Where-Object {"IsEncodedBase64" -notmatch $_.name} | 
	Select-Object Name |
	Get-Help | 
	Select-Object Name,Synopsis

	#"`n`n`rNCentral statuscodes"
	$_NCsession.ncstatus.getenumerator()|
	Select-object @{n="StatusCode";e={$_.Key}},
				@{n="Description";e={$_.Value}} |
	Sort-Object StatusCode | 
	Format-Table

}

Function Get-NCVersion{
	<#
	.Synopsis
	Returns the N-Central Version(s) of the connected server.
	
	.Description
	Returns the N-Central Version(s) of the connected server,
	and a list of status codes and descriptions.
	
	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false,	#Show API-Host version info
			HelpMessage = 'Show API-Host version info')]
			[Alias('FullVersionList','Full')]
		[Switch]$APIVersion,
		
		[Parameter(Mandatory=$false,	#Show N-Central GUI version only
			HelpMessage = 'Show N-Central GUI version only')]
			[Alias('VersionOnly')]
		[Switch]$Plain,
		
		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}
	Process{
		## API-version info
		If ($APIVersion){
			#Write-Output 
			$NcSession.NCVersionRequest() | Format-table
		}

		## Connection info
		If ($Plain){
			#Write-Output 
			$NcSession.NCVersion
		}
		Else{
			#Write-Output 
			$NcSession
		}
	}
	End{
	}
}

Function Get-NCTimeOut{
	<#
	.Synopsis
	Returns the max. time in seconds to wait for data returning from a (Synchronous) NCentral API-request.

	.Description
	Shows the maximum time to wait for synchronous data-request. Dialog in seconds.

	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
    )
	Begin{
			If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}
	Process{
#		Write-Output ($NCSession.Connection.TimeOut/1000)
		#Write-Output ($NCSession.RequestTimeOut)
		$NCSession.RequestTimeOut
	}
	End{}
}

Function Set-NCTimeOut{
	<#
	.Synopsis
	Sets the max. time in seconds to wait for data returning from a (Synchronous) NCentral API-request.

	.Description
	Sets the maximum time to wait for synchronous data-request. Time in seconds.
	Range: 15-600. Default is 100.

	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false,	#TimeOut for NCentral Requests in Seconds
			HelpMessage = 'TimeOut for NCentral Requests in Seconds')]
		[Int]$TimeOut,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
    )
	Begin{
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}

		## Limit Range. Set to Default (100000) if too small or no value is given.
#		$TimeOut = $TimeOut * 1000
		If ($TimeOut -lt 15){
			Write-Host "Minimum TimeOut is 15 Seconds. Is now reset to default; 100 seconds"
			$TimeOut = 100
		}
		If ($TimeOut -gt 600){
			Write-Host "Maximum TimeOut is 600 Seconds. Is now reset to Max; 600 seconds"
			$TimeOut = 600
		}
	}
	Process{
#		$NCSession.Connection.TimeOut = ($TimeOut * 1000)
		$NCSession.RequestTimeOut = $TimeOut
#		Write-Output ($NCSession.Connection.TimeOut)
		#Write-Output ($NCSession.RequestTimeOut)
		$NCSession.RequestTimeOut
	}
	End{}
}
#EndRegion Module-support

#Region Customers
Function Get-NCServiceOrganizationList{
	<#
	.Synopsis
	Returns a list of all ServiceOrganizations and their data.

	.Description
	Returns a list of all ServiceOrganizations and their data.

	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}	
	Process{

	}
	End{
		#Write-Output 
		$NcSession.CustomerList($true)
	}
}

Function Get-NCCustomerList{
	<#
	.Synopsis
	Returns a list of all customers and their data. ChildrenOnly when CustomerID is specified.

	.Description
	Returns a list of all customers and their data.
	ChildrenOnly when CustomerID is specified.


	## TODO - Integrate Custom-properties
	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false,	#Existing Customer ID or empty for Default Customer
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Existing Customer ID or empty for Default Customer')]
		## Default-value is essential for output-selection.
		$CustomerID = 0,

		[Parameter(Mandatory=$false,	#Refresh Cached CustomerList
			HelpMessage = 'Refresh Cached CustomerList')]
			[Alias("Renew")]
		[Switch]$Force,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}	
	Process{
		Write-Debug "CustomerID: $CustomerID"
		If ($CustomerID){
			## Return direct children only.
			$ReturnData =  $NcSession.CustomerListChildren($CustomerID)
		}
		Else{
			## Return all Customers and sites

			## Fill/refresh cache
			If ((!$NcSession.CustomerData) -or ($Force)){
				$NcSession.CustomerData = $NcSession.CustomerList() | Sort-Object customername

				## Set DefaultCustomer to top-level if not set yet.
				$DefaultCustomer = ($NcSession.CustomerData.parentid | Measure-Object -minimum).minimum
				If ($NcSession.DefaultCustomerID -lt $DefaultCustomer){
					$NcSession.DefaultCustomerID = $DefaultCustomer
				}
			}
			## Return data from cache
			$ReturnData = $NcSession.CustomerData
		}
	}
	End{
		## Alphabetical Columnnames
		$ReturnData | 
		Select-Object ($ReturnData|Get-Member -type Noteproperty -ErrorAction SilentlyContinue).name -ErrorAction SilentlyContinue |
		## Put important fields in front.
		Select-Object customerid,customername,externalid,externalid2,* -ErrorAction SilentlyContinue 
		#| Write-Output
	}
}

Function Set-NCCustomerDefault{
	<#
	.Synopsis
	Sets the DefaultCustomerID to be used.
	
	.Description
	Sets the DefaultCustomerID to be used, when not supplied as parameter.
	Standard-value: 50 (First Service Organization created).
		
	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false,	#Existing Customer ID
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Existing Customer ID')]
		[int]$CustomerID,
		
		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
				HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
		If(!$CustomerID){
			$CustomerID = 50
		}
	}	
	Process{
		$NcSession.DefaultCustomerID = $CustomerID
		Write-Host ("Default CustomerID now set to: {0}" -f $CustomerID)
	}
	End{
	}
}

Function Get-NCCustomerPropertyList{
	<#
	.Synopsis
	Returns a list of all (Custom-)Properties for the selected CustomerID(s).

	.Description
	Returns a list of all Custom-Properties for the selected customers.
	Optionally include the default properties (-Full option)
	If no customerIDs are supplied, data for all customers will be returned.

	## Uses (cached) NCCustomerList for -Full option.
	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false,	#Array of Existing Customer IDs
			ValueFromPipeline = $true,
			#ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Array of Existing Customer IDs')]
			[Alias("CustomerID")]
		[Array]$CustomerIDs,
		
		[Parameter(Mandatory=$false,	#Include default Customer Properties
			HelpMessage = 'Include default Customer Properties')]
			[Alias('All')]
		[Switch]$Full,

		[Parameter(Mandatory=$false,	#No Sorting of the output
			HelpMessage = 'No Sorting of the output')]
			[Alias('UnSorted')]
		[Switch]$NoSort,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
	
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	
	}
	Process{
		#Create an Array of all IDs To collect in one Call if possible.
		IF($customerIDs){
			## Recieved List of Objects or individual IDs?
			$IsObjectsArray = $false
			Try{
				If($CustomerIDs[0].customerid){$IsObjectsArray = $true}
			}
			Catch{}

			$CustomerArray = $null
			If($IsObjectsArray){
				[array]$CustomerArray = $CustomerIDs.customerid
			}else{
				[array]$CustomerArray = $CustomerIDs
			}
		}

		$ReturnData = $NcSession.OrganizationPropertyList($CustomerArray)
		#$ReturnData = $NcSession.OrganizationPropertyList($CustomerIDs)

		If ($Full -and $ReturnData){
			## Add all standard properties
			## from $NCSession.customerlist()

			## Init
			$Customers = $ReturnData
			$Returndata2 = @()

			## Build new Object(s)
			ForEach($Customer in $Customers ){
				## (Re-)init Object-properties.
				$CustomerSettings = @{}

				# Add Custom Properties - from result
				$CCustomerProps = ($Customer|Get-Member -type Noteproperty).name
				foreach($CProperty in $CCustomerProps){
					$PropertyValue = $Customer."$CProperty"
					$CustomerSettings."$CProperty" = $PropertyValue
				}
				# Add Standard Properties - from internal cache
				$CustomerProps = ($NCSession.customerlist()).Where({ $_.customerid -eq $Customer.customerid})
				foreach($SProperty in $NCsession.CustomerValidation){
					$PropertyValue = $CustomerProps.$SProperty
					$CustomerSettings.$SProperty = $PropertyValue
				}

				## Add each Object to the new Array.
				$ReturnData2 += (New-Object -TypeName PSObject -Property $CustomerSettings)
			}
			## Return list of enhanced objects
			$ReturnData = $ReturnData2
		}

		If($NoSort){
			$ReturnData 
			#| Write-Output
		}
		Else{
			## Determine all unique colums over all items. Columns can vary per asset-class.
			$NCSession.FixProperties($ReturnData) | 
			## Alphabetical Columnnames	--> included in fixproperties
			#$ReturnData | Select-Object ($ReturnData|Get-Member -type Noteproperty -ErrorAction SilentlyContinue).name -ErrorAction SilentlyContinue |
			## Make CustomerID the first column.
			Select-Object customerid,* -ErrorAction SilentlyContinue 
			#| Write-Output
		}
	}
	End{
	}
}

Function Set-NCCustomerProperty{
	<#
	.Synopsis
	Fills the specified property(name) for the given CustomerID(s). Base64 optional.

	.Description
	Fills the specified property(name) for the given CustomerID(s).
	This can be a default or custom property.
	CustomerID(s) must be supplied.
	Properties are cleared if no Value is supplied.
	Optional Base64 encoding (UniCode/UTF16).

	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$true,		#Array of Existing Customer IDs
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Array of Existing Customer IDs')]
			[Alias("CustomerID")]
		[Array]$CustomerIDs,

		[Parameter(Mandatory=$true,		#Name of the Customer (Custom-)Property
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 1,
			HelpMessage = 'Name of the Customer (Custom-)Property')]
			[Alias("PropertyName")]
		[String]$PropertyLabel,

		[Parameter(Mandatory=$false,	#Value for the Customer Property
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 2,
			HelpMessage = 'Value for the Customer Property')]
		[String]$PropertyValue = '',

		[Parameter(Mandatory=$false,	#Encode the PropertyValue (Base64)
			HelpMessage = 'Encode the PropertyValue (Base64)')]
			[Alias("Encode")]
		[Switch]$Base64,
			
		[Parameter(Mandatory=$false,	##Optional with -Encode; Use UTF8 Encoding iso UniCode
			HelpMessage = 'Use UTF8 Encoding iso UniCode')]
		[Switch]$UTF8,
			
		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		$CustomerProperty = $false
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
#		If (!$PropertyValue){
#			Write-Host "CustomerProperty '$PropertyLabel' will be cleared."
#		}
		If ($NcSession.CustomerValidation -contains $PropertyLabel){
			## This is a standard CustomerProperty.
			$CustomerProperty = $true
		}
	}
	Process{
		## Encode Data if requested
		If ($Base64){
			$PropertyValue = $NCSession.ConvertBase64($PropertyValue,$false,$UTF8)
		}

		ForEach($CustomerID in $CustomerIDs ){
			## Differentiate between Standard(Customer) and Custom(Organization) properties.
			If ($CustomerProperty){
				$NcSession.CustomerModify($CustomerID, $PropertyLabel, $PropertyValue)
			}
			Else{
				$NcSession.OrganizationPropertyModify($CustomerID, $PropertyLabel, $PropertyValue)
			}
		}
	}
	End{
	}
}

Function Get-NCCustomerProperty{
	<#
	.Synopsis
	Retrieve the Value of the specified property(name) for the Customer(ID). Base64 optional.
	
	.Description
	Retrieve the Value of the specified property(name) for the Customer(ID).
	This can be a default or custom property.
	CustomerID and Propertyname must be supplied.
	(Save) Base64 decoding optional.
	
	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$true,
#               ValueFromPipeline = $true,
				ValueFromPipelineByPropertyName = $true,
				Position = 0,
				HelpMessage = 'Existing Customer ID')]
			[Alias("ID")]
		[int]$CustomerID,

		[Parameter(Mandatory=$true,		#Name of the Customer Custom-Property
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 1,
			HelpMessage = 'Name of the Customer Custom-Property')]
			[Alias("PropertyName")]
		[String]$PropertyLabel,
			
		[Parameter(Mandatory=$false,	#Decode the PropertyValue if needed (Base64)
			HelpMessage = 'Decode the PropertyValue if needed (Base64)')]
			[Alias("Decode")]
		[Switch]$Base64,

		[Parameter(Mandatory=$false,	#Optional with -Decode; Use UTF8 Encoding iso UniCode
			HelpMessage = 'Use UTF8 Encoding iso UniCode')]
		[Switch]$UTF8,
			
		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		$CustomerProperty = $false
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
		If ($NcSession.CustomerValidation -contains $PropertyLabel){
			## This is a standard CustomerProperty.
			$CustomerProperty = $true
		}
	}
	Process{
		## Differentiate between Standard(Customer) and Custom(Organization) properties.
		If ($CustomerProperty){
			#$this.CustomerPropertyValue($CustomerID,"CustomerName")
			$ReturnData = $NcSession.CustomerPropertyValue($CustomerID,$PropertyLabel)
		}
		Else{
			$ReturnData = ($NcSession.OrganizationPropertyList($CustomerID)).$PropertyLabel
		}

		## Decode if requested
		If ($Base64){
			If($Returndata){
				$Returndata = $NCSession.ConvertBase64($ReturnData,$true,$UTF8)
			}
		}
	}
	End{
		$Returndata 
		#| Write-Output
	}
}

Function Add-NCCustomerPropertyValue{
	<#
	.Synopsis
	The Value is added to the comma-separated string of unique values in the Customer Property.
	
	.Description
	The Value is added to the comma-separated string of unique values in the Customer Property.
	Case-sensivity is optional.

	
	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$true,		#Existing Customer ID
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Existing Customer ID')]
		[int]$CustomerID,
			
		[Parameter(Mandatory=$true,		#Existing Customer Property (name)
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 1,
			HelpMessage = 'Existing Customer Property (name)')]
			[Alias("PropertyLabel","Property","CustomProperty")]
		[string]$PropertyName,

		[Parameter(Mandatory=$true,		#Value to Add to the String
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 2,
			HelpMessage = 'Value to Add to the String')]
			[Alias("Value")]
		[string]$ValueToInsert,

		[Parameter(Mandatory=$false,	#Preserve Case
			HelpMessage = 'Preserve Case')]
			[Alias('UseCase')]
		[Switch]$CaseSensitive,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}
	Process{
		## Remove Existing
		If ($CaseSensitive){
			[system.collections.arraylist]$ValueList = (Remove-NCCustomerPropertyValue $CustomerID $PropertyName $ValueToInsert -UseCase) -split ","
		}
		Else{
			[system.collections.arraylist]$ValueList = (Remove-NCCustomerPropertyValue $CustomerID $PropertyName $ValueToInsert) -split ","
		}

		## Refresh empty List
		If(!$ValueList){
			$ValueList = @()
		}

		## Add the new Value
		$ValueList += $ValueToInsert.Trim()

		## Sort, Convert and Save
		$ReturnData = ($ValueList | Sort-Object ) -join ","
		## Write data back to DeviceProperty
		Set-NCCustomerProperty $CustomerID $PropertyName $ReturnData
	}
	End{
		## Return new values
		$ReturnData 
		#| Write-Output
	}
}

Function Remove-NCCustomerPropertyValue{
	<#
	.Synopsis
	The Value is removed from the comma-separated string of unique values in the Customer Property.
	
	.Description
	The Value is removed from the comma-separated string of unique values in the Customer Property.
	Case-sensivity is optional.

	
	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$true,		#Existing Customer ID
#               ValueFromPipeline = $true,
				ValueFromPipelineByPropertyName = $true,
				Position = 0,
				HelpMessage = 'Existing Customer ID')]
		[int]$CustomerID,
			
		[Parameter(Mandatory=$true,		#Existing Customer Property (name)
#               ValueFromPipeline = $true,
				ValueFromPipelineByPropertyName = $true,
				Position = 1,
				HelpMessage = 'Existing Customer Property (name)')]
			[Alias("PropertyLabel","Property","CustomProperty")]
		[string]$PropertyName,

		[Parameter(Mandatory=$true,		#Value to Remove from the String
#               ValueFromPipeline = $true,
				ValueFromPipelineByPropertyName = $true,
				Position = 2,
				HelpMessage = 'Value to Remove from the String')]
			[Alias("Value")]
		[string]$ValueToDelete,

		[Parameter(Mandatory=$false,	#Preserve Case
				HelpMessage = 'Preserve Case')]
			[Alias('UseCase')]
		[Switch]$CaseSensitive,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
				HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
		
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}

	Process{
		$ReturnData = $null
		[system.collections.arraylist]$ValueList = (Get-NCCustomerProperty $CustomerID $PropertyName) -split ","

		## Check if values are retrieved
		If($ValueList){
			If ($CaseSensitive){
				$ValueList.remove($ValueToDelete)
			}
			Else{
				$ValueList =$ValueList.Where{$_ -ne "$ValueToDelete"}
				#$ValueList =$ValueList | Where-Object -FilterScript {$_ -ne "$ValueToDelete"}
			}
			$ReturnData = ( $ValueList | Sort-Object ) -join ","

			## Write data back to DeviceProperty
			Set-NCCustomerProperty $CustomerID $PropertyName $ReturnData
		}
	}
	End{
		$ReturnData 
		#| Write-Output
	}
}

Function Get-NCProbeList{
	<#
	.Synopsis
	Returns the Probes for the given CustomerID(s).

	.Description
	Returns the Probes for the given CustomerID(s).
	If no customerIDs are supplied, all probes will be returned.

	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false,	#Existing Customer ID
			ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Existing Customer ID')]
			[Alias("CustomerID")]
		[Array]$CustomerIDs,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
		If (!$CustomerIDs){
			Write-Host "No CustomerID specified."
			If (!$NcSession.DefaultCustomerID){
				Break
			}
			$CustomerIDs = $NcSession.DefaultCustomerID
			Write-Host ("Using current default CustomerID {0} for NCProbeList." -f $CustomerIDs)
		}
	}
	Process{
		ForEach ($CustomerID in $CustomerIDs){
			$NcSession.DeviceList($CustomerID,$false,$true)|
			Select-Object deviceid,@{n="customerid"; e={$CustomerID}},customername,longname,url,* -ErrorAction SilentlyContinue 
			#| Write-Output 
		}
	}
	End{
	}

}
#EndRegion

#Region Devices
Function Get-NCDeviceList{
	<#
	.Synopsis
	Returns the Managed Devices for the given CustomerID(s) and Sites below.

	.Description
	Returns the Managed Devices for the given CustomerID(s) and Sites below.
	If no customerIDs are supplied, all managed devices will be returned.

	## TODO - Confirmation if no CustomerID(s) are supplied (Full List).
	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false,	#Existing Customer ID
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Existing Customer ID')]
			[Alias("customerid")]
		[array]$CustomerIDs,

		[Parameter(Mandatory=$false,	#No Sorting of the output
			HelpMessage = 'No Sorting of the output')]
			[Alias('UnSorted')]
		[Switch]$NoSort,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
		If (!$CustomerIDs){
			## this should be skipped when coming from an empty pipeline object.
			#Write-host ("CustomerIDs = {0}" -f $CustomerIDs)
			Write-Host "No CustomerID specified."
			If (!$NcSession.DefaultCustomerID){
				Break
			}
			$CustomerIDs = $NcSession.DefaultCustomerID
			Write-Host ("Using current default CustomerID {0} for NCDeviceList." -f $CustomerIDs)
		}
	}
	Process{
		ForEach ($CustomerID in $CustomerIDs){
			#Write-host ("CustomerID = {0}." -f $CustomerID)
			$ReturnData = $NcSession.DeviceList($CustomerID)

			If($NoSort){
				$ReturnData 
				#| Write-Output
			}
			Else{
				$ReturnData | 
				## Alphabetical Columnnames
				Select-Object ($ReturnData|Get-Member -type Noteproperty -ErrorAction SilentlyContinue).name -ErrorAction SilentlyContinue |
				## CustomerID is not returned by default. Added as custom field.
				Select-Object deviceid,@{n="customerid"; e={$CustomerID}},customername,sitename,longname,uri,* -ErrorAction SilentlyContinue 
				#| Write-Output
			}
		}
	}
	End{
	}
}

Function Get-NCDeviceID{
	<#
	.Synopsis
	Returns the DeviceID(s) for the given DeviceName(s). Case Sensitive, No Wildcards.

	.Description
	The returned objects contain extra information for verification.
	The supplied name(s) are Case Sensitive, No Wildcards allowed. 
	Also not-managed devices are returned.
	Nothing is returned for names not found.

	Alias for Get-NCDevicePropertyList -DeviceName <Names-Array>
	#>
	
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$true,		#Array of DeviceNames
			ValueFromPipeline = $true,
			#ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Array of DeviceNames')]
			#[Alias("Name")]
		[Array]$DeviceNames,
		
		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
		If (!$DeviceNames){
			Write-Host "No DeviceName(s) given."
			Break
		}
	}
	Process{
		## Collect the data for all Names. Case Sensitive, No Wildcards.
		## Only Returns found devices.
				
		ForEach ($DeviceName in $DeviceNames){
			## Use the NameFilter of the DevicePropertyList to find the DeviceID for now.
			## Limited Filter-options, but fast.
			$NcSession.DevicePropertyList($null,$DeviceName,$null,$null) |
			## Add additional Info and return only selected fields/Columns
			Get-NCDeviceInfo |
			Select-Object DeviceID,LongName,DeviceClass,CustomerID,CustomerName,IsManagedAsset 
			#| Write-Output
		}
	
	}
	End{
	}
}

Function Get-NCDeviceLocal{
	<#
	.Synopsis
	Returns the DeviceID, CustomerID and some more Info for the Local Computer.

	.Description
	Queries the local ApplicationID and returns the NCentral DeviceID.
	No Parameters recquired.
	
	#>
	
	[CmdletBinding()]

	Param(
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
        $ApplianceConfig = ("{0}\N-able Technologies\Windows Agent\config\ApplianceConfig.xml" -f ${Env:ProgramFiles(x86)})
        $ServerConfig = ("{0}\N-able Technologies\Windows Agent\config\ServerConfig.xml" -f ${Env:ProgramFiles(x86)})

		If (-not (Test-Path $ApplianceConfig -PathType leaf)){
			Write-Host "No Local NCentral-agent Configuration found."
			Write-Host "Try using 'Get-NCDeviceID $Env:ComputerName'."
			Break
		}
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}
	Process{
        # Get appliance id
        $ApplianceXML = [xml](Get-Content -Path $ApplianceConfig)
        $ApplianceID = $ApplianceXML.ApplianceConfig.ApplianceID
		# Get management Info.
        $ServerXML = [xml](Get-Content -Path $ServerConfig)
		$ServerIP = $ServerXML.ServerConfig.ServerIP
		$ConnectIP = $NcSession.ConnectionURL

		If($ServerIP -ne $ConnectIP){
			Write-Host "The Local Device is Managed by $ServerIP. You are connected to $ConnectIP."
		}
		
		$NcSession.DeviceGetAppliance($ApplianceID)|
		## Return all Info, since already collected.
		Select-Object deviceid,longname,@{Name="managedby"; Expression={$ServerIP}},customerid,customername,deviceclass,licensemode,* -ErrorAction SilentlyContinue 
		#| Write-Output
	}
	End{
	}
}

Function Get-NCDevicePropertyList{
	<#
	.Synopsis
	Returns the Custom Properties of the DeviceID(s).

	.Description
	Returns the Custom Properties of the DeviceID(s).
	If no devviceIDs are supplied, all managed devices
	and their Custom Properties will be returned.

	## TODO - Confirmation if no DeviceID(s) are supplied (Full List). Only warning now.
	## Issue: Only properties of first item are added/displayed for all Devices in a list.
	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false,	#Existing Device IDs
			ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Existing Device IDs')]
			[Alias("DeviceID")]
		[Array]$DeviceIDs,

		[Parameter(Mandatory=$false,	#Existing Device Names
			HelpMessage = 'Existing Device Names')]
			[Alias("DeviceName")]
		[Array]$DeviceNames,

		[Parameter(Mandatory=$false,	#Existing Filter IDs
			HelpMessage = 'Existing Filter IDs')]
			[Alias("FilterID")]
		[Array]$FilterIDs,

		[Parameter(Mandatory=$false,	#Existing Filter Names
			HelpMessage = 'Existing Filter Names')]
			[Alias("FilterName")]
		[Array]$FilterNames,

		[Parameter(Mandatory=$false,	#No Sorting of the output
			HelpMessage = 'No Sorting of the output')]
			[Alias('UnSorted')]
		[Switch]$NoSort,

		[Parameter(Mandatory=$false,	#Show processing progress
			HelpMessage = 'Show processing progress')]
			[Alias('Progress')]
		[Switch]$ShowProgress,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}
	Process{
		## Create an Array of all DevicesIDs To collect in one Call.
		$DeviceArray = $null
		If($DeviceIDs){
			## Recieved List of Objects or individual IDs?
			$IsObjectsArray = $false
			Try{
				If($DeviceIDs[0].deviceid){$IsObjectsArray = $true}
			}
			Catch{}
			#Write-Host $IsObjectsArray

			If($IsObjectsArray){
				[array]$DeviceArray = $DeviceIDs.deviceid
			}Else{
				[array]$DeviceArray = $DeviceIDs
			}
		}
		
		## Debug
		#Write-Host $DeviceIDs
		#Write-Host $DeviceArray.Count
		#Write-Host $DeviceArray
		#Write-Host ("Sent {0}." -f ($DeviceArray -join ","))

		## Limited or Full list
		If ($DeviceArray -or $DeviceNames -or $FilterIDs -or $FilterNames ){
			#$Returndata = $NcSession.DevicePropertyList($DeviceIDs,$DeviceNames,$FilterIDs,$FilterNames)
			$Returndata2 = $NcSession.DevicePropertyList($DeviceArray,$DeviceNames,$FilterIDs,$FilterNames,$ShowProgress)
			$ncsession.TestVar = $Returndata2 
			#Write-host ("Received {0}." -f $ReturnData.deviceid -join ",")
			#Write-host $ReturnData.deviceid
		}
		Else{
			Write-Host "Generating a full DevicePropertyList may take some time, and possibly timeout." -ForegroundColor Red
			Write-Host "Preferred to use a Filter-Name or -ID. Use 'Get-Help Get-NCDevicePropertyList -detail' to see the parameter options.`r`n"
			
			$ReturnData2 = $NcSession.DevicePropertyList($null,$null,$null,$null,$ShowProgress)

			Write-Host "Data retrieved, processing output."
		}

		If ($NoSort){
			$ReturnData2 
			#| Write-Output
		}
		Else{
			## Determine all unique colums over all items. Columns can vary per asset-class.
			$Returndata2 |
			#$NCSession.FixProperties($ReturnData) | 		## Fixed in ProcessData1
			## Alphabetical Columnnames	--> included in fixproperties
			Select-Object ($ReturnData|Get-Member -type Noteproperty -ErrorAction SilentlyContinue).name -ErrorAction SilentlyContinue |

			## Make DeviceID the first column.
			Select-Object deviceid,* -ErrorAction SilentlyContinue 
			#| Write-Output
		}
	}
	End{
	}
}

Function Get-NCDevicePropertyListFilter{
	<#
	.Synopsis
	Returns the Custom Properties of the Devices within the FilterID(s).

	.Description
	Returns the Custom Properties of the Devices within the FilterID(s).
	A filterID must be supplied. Hoover over the filter in the GUI to reveal its ID.

	Replaced by the Get-NCDevicePropertyList -FilterID.
	Included for backward compatibility

	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$true,		#Array of existing Filter IDs
			ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Array of existing Filter IDs')]
			[Alias("FilterID")]
		[Array]$FilterIDs,
		
		[Parameter(Mandatory=$false,	#No Sorting of the output
			HelpMessage = 'No Sorting of the output')]
			[Alias('UnSorted')]
		[Switch]$NoSort,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
		If (!$FilterIDs){
			Write-Host "No FilterIDs given."
			Break
		}
	}
	Process{
		#Collect the data for all IDs.
		
		If($NoSort){
			Get-NCDevicePropertyList -FilterId $FilterIDs -NoSort
		}
		Else{
			Get-NCDevicePropertyList -FilterId $FilterIDs
		}
<#
		ForEach ($FilterID in $FilterIDs){
			$ReturnData = $NcSession.DevicePropertyList($null,$null,$FilterID,$null)

			If($NoSort){
				$ReturnData | Write-Output
			}
			Else{
				## Alphabetical Columnnames
				$ReturnData | Select-Object ($ReturnData|Get-Member -type Noteproperty -ErrorAction SilentlyContinue).name -ErrorAction SilentlyContinue |
				## Make DeviceID the first column.
				Select-Object deviceid,* -ErrorAction SilentlyContinue |
				Write-Output
			}

		}
#>	
	}
	End{
	}
}

Function Set-NCDeviceProperty{
	<#
	.Synopsis
	Set the value of the Custom Property for the DeviceID(s). Base64 optional.
	
	.Description
	Set the value of the Custom Property for the DeviceID(s).
	Existing values are overwritten, Properties are cleared if no Value is supplied.
	Optional Base64 Encoding (Unicode/UTF16).
	
	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$true,		#Existing Device IDs
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Existing Device IDs')]
			[Alias("DeviceID")]
		[Array]$DeviceIDs,

		[Parameter(Mandatory=$true,		#Name of the Device Custom-Property
			#ValueFromPipeline = $true,
			#ValueFromPipelineByPropertyName = $true,
			Position = 1,
			HelpMessage = 'Name of the Device Custom-Property')]
			[Alias("PropertyName")]
		[String]$PropertyLabel,

		[Parameter(Mandatory=$false,	#Value for the Device Custom-Property or empty to clear
			#ValueFromPipeline = $true,
			#ValueFromPipelineByPropertyName = $true,
			Position = 2,
			HelpMessage = 'Value for the Device Custom-Property or empty to clear')]
			[Alias("Value")]
		[String]$PropertyValue,
		
		[Parameter(Mandatory=$false,	#Encode the PropertyValue (Base64)
			HelpMessage = 'Encode the PropertyValue (Base64)')]
			[Alias("Encode")]
		[Switch]$Base64,
					
		[Parameter(Mandatory=$false,	##Optional with Encode; Use UTF8 Encoding iso UniCode
			HelpMessage = 'Use UTF8 Encoding iso UniCode')]
		[Switch]$UTF8,
			
		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
#		If (!$DeviceIDs){
#			## Issue when value comes from pipeline. Use Parameter-validation.
#			Write-Host "No DeviceID specified."
#			Break
#		}
#		If (!$PropertyLabel){
#			## Use Parameter-validation.
#			Write-Host "No Property-name specified."
#			Break
#		}
		If (!$PropertyValue){
			#Write-Host "DeviceProperty '$PropertyLabel' will be cleared."
			$PropertyValue=$null
		}
	}
	Process{
		## Encode if requested
		If ($Base64){
			$PropertyValue = $NCSession.ConvertBase64($PropertyValue,$false,$UTF8)
		}

		ForEach($DeviceID in $DeviceIDs ){
			$NcSession.DevicePropertyModify($DeviceID, $PropertyLabel, $PropertyValue)
		}
	}
	End{
	}
}

Function Get-NCDeviceProperty{
	<#
	.Synopsis
	Returns the Value of the Custom Device Property. Base64 optional.
	
	.Description
	Returns the Value of the Custom Device Property.
	(Save) Base64 decoding optional.
	
	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$true,		#Existing Device ID
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Existing Device ID')]
			[Alias("ID")]
		[int]$DeviceID,
			
		[Parameter(Mandatory=$true,		#Existing Custom Device Property (name)
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 1,
			HelpMessage = 'Existing Custom Device Property (name)')]
			[Alias("Property","CustomProperty")]
		[string]$PropertyName,
			
		[Parameter(Mandatory=$false,	#Decode the PropertyValue if needed
			HelpMessage = 'Decode the PropertyValue if needed')]
			[Alias("Decode")]
		[Switch]$Base64,
		
		[Parameter(Mandatory=$false,	#Optional with -Decode; Use UTF8 Encoding iso UniCode
			HelpMessage = 'Use UTF8 Encoding iso UniCode')]
		[Switch]$UTF8,
			
		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}
	Process{
		$ReturnData = ($NcSession.DevicePropertyList($DeviceID,$null,$null,$null).$PropertyName)

		## Decode if requested
		If($Base64){
			If($ReturnData){
				$ReturnData = $NCSession.ConvertBase64($ReturnData,$true,$UTF8)
			}
		}
	}
	End{
		$ReturnData 
		#| Write-Output	
	}
#>
}

Function Add-NCDevicePropertyValue{
	<#
	.Synopsis
	The Value is added to the comma-separated string of unique values in the Custom Device Property.
	
	.Description
	The Value is added to the comma-separated string of unique values in the Custom Device Property.
	Case-sensivity is optional.

	
	#>
	[CmdletBinding()]
	
	Param(
		[Parameter(Mandatory=$true,		#Existing Device ID
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Existing Device ID')]
		[int]$DeviceID,
			
		[Parameter(Mandatory=$true,		#Existing Custom Device Property (name)
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 1,
			HelpMessage = 'Existing Custom Device Property (name)')]
			[Alias("PropertyLabel","Property","CustomProperty")]
		[string]$PropertyName,

		[Parameter(Mandatory=$true,		#Value to Add to the String
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 2,
			HelpMessage = 'Value to Add to the String')]
			[Alias("Value")]
		[string]$ValueToInsert,

		[Parameter(Mandatory=$false,	#Preserve Case
			HelpMessage = 'Preserve Case')]
			[Alias('UseCase')]
		[Switch]$CaseSensitive,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
		
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}
	Process{
		## Retrieve Existing values
		#[system.collections.arraylist]$ValueList = (Get-NCDeviceProperty $DeviceID $PropertyName) -split ","

		## Remove Existing
		If ($CaseSensitive){
			[system.collections.arraylist]$ValueList = (Remove-NCDevicePropertyValue $DeviceID $PropertyName $ValueToInsert -UseCase) -split ","
		}
		Else{
			[system.collections.arraylist]$ValueList = (Remove-NCDevicePropertyValue $DeviceID $PropertyName $ValueToInsert) -split ","
		}

		## Refresh empty List
		If(!$ValueList){
			$ValueList = @()
		}

		## Add the new Value
		$ValueList += $ValueToInsert.Trim()
<#
		## Remove duplicate values. Is applied to existing values also. 
		If ($CaseSensitive){
			$ReturnData = ($ValueList | Select-Object -Unique |Sort-Object) -join ","
			#$ReturnData = ($ValueList | Get-Unique -AsString | Sort-Object) -join ","
		}
		Else{
			$ReturnData = ($ValueList | Sort-Object -Unique ) -join ","
		}
#>
		## Sort, Convert and Save
		$ReturnData = ($ValueList | Sort-Object ) -join ","
		## Write data back to DeviceProperty
		Set-NCDeviceProperty $DeviceID $PropertyName $ReturnData
	}
	End{
		## Return new values
		$ReturnData 
		#| Write-Output
	}
}

Function Remove-NCDevicePropertyValue{
	<#
	.Synopsis
	The Value is removed from the comma-separated string of unique values in the Custom Device Property.
	
	.Description
	The Value is removed from the comma-separated string of unique values in the Custom Device Property.
	Case-sensivity is optional.

	
	#>
	[CmdletBinding()]
	
	Param(
		[Parameter(Mandatory=$true,		#Existing Device ID
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Existing Device ID')]
		[int]$DeviceID,
			
		[Parameter(Mandatory=$true,		#Existing Custom Device Property
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 1,
			HelpMessage = 'Existing Custom Device Property')]
			[Alias("Property","CustomProperty")]
		[string]$PropertyName,

		[Parameter(Mandatory=$true,		#Value to Remove from the String
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 2,
			HelpMessage = 'Value to Remove from the String')]
			[Alias("Value")]
		[string]$ValueToDelete,

		[Parameter(Mandatory=$false,	#Preserve Case
			HelpMessage = 'Preserve Case')]
			[Alias('UseCase')]
		[Switch]$CaseSensitive,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}

	Process{
		$ReturnData = $null
		[system.collections.arraylist]$ValueList = (Get-NCDeviceProperty $DeviceID $PropertyName) -split ","

		## Check if values are retrieved
		If($ValueList){
			If ($CaseSensitive){
				$ValueList.remove($ValueToDelete)
			}
			Else{
				$ValueList =$ValueList.Where{$_ -ne "$ValueToDelete"}
				#$ValueList =$ValueList | Where-Object -FilterScript {$_ -ne "$ValueToDelete"}
			}
			$ReturnData = ( $ValueList | Sort-Object ) -join ","

			## Write data back to DeviceProperty
			Set-NCDeviceProperty $DeviceID $PropertyName $ReturnData
		}
	}
	End{
		$ReturnData 
		#| Write-Output
	}
}

Function Get-NCDeviceInfo{
	<#
	.Synopsis
	Returns the General details for the DeviceID(s).

	.Description
	Returns the General details for the DeviceID(s).
	DeviceID(s) must be supplied, as a parameter or by PipeLine.
	Use Get-NCDeviceObject tot retrieve ALL details of a device.

	#>
	[CmdletBinding(DefaultParameterSetName='NonPipeline')]

	Param(
		[Parameter(Mandatory=$true,		#Existing Device IDs
			ValueFromPipeline = $true,
			#ValueFromPipelineByPropertyName = $false,
			Position = 0,
			HelpMessage = 'Existing Device IDs')]
			[Alias("DeviceID")]
		[Array]$DeviceIDs,
		
		[Parameter(Mandatory=$false,	#Show processing progress
			HelpMessage = 'Show processing progress')]
			[Alias('Progress')]
		[Switch]$ShowProgress,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}
	Process{
		## Create an Array of all DevicesIDs To collect in one Call.
		$DeviceArray = $null
		If($DeviceIDs){
			## Recieved List of Objects or individual IDs?
			$IsObjectsArray = $false
			Try{
				If($DeviceIDs[0].deviceid){$IsObjectsArray = $true}
			}
			Catch{}

			If($IsObjectsArray){
				[array]$DeviceArray = $DeviceIDs.deviceid
			}Else{
				[array]$DeviceArray = $DeviceIDs
			}
		}

		## Mutiple IDs are sent to the server in one call. 
		$NcSession.DeviceGet($DeviceArray,$ShowProgress)|
		Select-Object deviceid,longname,customerid,customername,deviceclass,licensemode,* -ErrorAction SilentlyContinue 
		#| Write-Output
	}
	End{
	}
}
	
Function Get-NCDeviceObject{
	<#
	.Synopsis
	Returns a Device and the asset-properties as an object.

	.Description
	Returns a Device and the asset-properties as an object.
	The asset-properties may contain multiple entries.

	You can pass an array of properties to be Included or Excluded.

	#>

	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false,	#Existing Device IDs
                ValueFromPipeline = $true,
				#ValueFromPipelineByPropertyName = $true,
				Position = 0,
				HelpMessage = 'Existing Device IDs')]
#			[ValidateScript({ $_ | ForEach-Object {(Get-Item $_).PSIsContainer}})]
			[Alias("DeviceID")]
			[Array]$DeviceIDs,

		[Parameter(Mandatory=$false,	#Existing Device Names
				HelpMessage = 'Existing Device Names')]
			[Alias("DeviceName")]
			[Array]$DeviceNames,

		[Parameter(Mandatory=$false,	#Existing Filter IDs
				HelpMessage = 'Existing Filter IDs')]
			[Alias("FilterID")]
			[Array]$FilterIDs,

		[Parameter(Mandatory=$false,	#Existing Filter Names
				HelpMessage = 'Existing Filter Names')]
			[Alias("FilterName")]
			[Array]$FilterNames,

		[Parameter(Mandatory=$false,	#Include categories
			Position = 1,
			HelpMessage = 'Include categories')]
			[Alias("CategoryInclude")]
		[Array]$Include,

		[Parameter(Mandatory=$false,	#Exclude categories
			Position = 2,
			HelpMessage = 'Exclude categories')]
			[Alias("CategoryExclude")]
		[Array]$Exclude,

		[Parameter(Mandatory=$false,	#Show processing progress
			HelpMessage = 'Show processing progress')]
			[Alias('Progress')]
		[Switch]$ShowProgress,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available

		#If(($DeviceIds.count + $DeviceNames.count + $FilterIDs.count + $FilterNames.count) -eq 0){
			#Write-host "At least one device-selector must be supplied."
			#Exit
		#}

		## Always include basic Device-properties
		If($Include){
			[System.Collections.ArrayList]$IncludeFilter = @()
			[void]$includeFilter.AddRange($include)
			[void]$includeFilter.Add("device")
		}

		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}

	}
	Process{
		#Collect the data for all IDs.

		## Additional processing when data comes from pipeline
		$DeviceArray = $null
		If($DeviceIDs){
			## Recieved List of Objects or individual IDs?
			$IsObjectsArray = $false
			Try{
				If($DeviceIDs[0].deviceid){$IsObjectsArray = $true}
			}
			Catch{}

			If($IsObjectsArray){
				[array]$DeviceArray = $DeviceIDs.deviceid
			}Else{
				[array]$DeviceArray = $DeviceIDs
			}
		}

		## Multiple IDs can be passed to the Class-method directly 
		#$ReturnData = $NcSession.DeviceAssetInfoExportDeviceWithSettings($DeviceIDs,$DeviceNames,$FilterIDs,$FilterNames,$Include,$Exclude)	
		$NcSession.DeviceAssetInfoExportDeviceWithSettings($DeviceArray,$DeviceNames,$FilterIDs,$FilterNames,$IncludeFilter,$Exclude,$ShowProgress)|
		Select-Object ($Returndata | Get-Member -type Noteproperty -ErrorAction SilentlyContinue).name -ErrorAction SilentlyContinue |
		Select-Object deviceid,longname,customerid,deviceclass,* -ErrorAction SilentlyContinue 
		#| Write-Output
	}
	End{
	}
}
#EndRegion

#Region Services and Tasks
Function Get-NCActiveIssuesList{
	<#
	.Synopsis
	Returns the Active Issues on the CustomerID-level and below.

	.Description
	Returns the Active Issues on the CustomerID-level and below.
	An additional Search/Filter-string can be supplied.

	If no customerID is supplied, Default Customer is used.
	The SiteID of the devices is returned (Not CustomerID).

	-IssueSearchBy searches the given string in the fields:
	so, site, device, deviceClass, service, transitionTime, notification, features, deviceID, and ip address.

	-IssueStatus option (or as 3th parameter):
	1	No Data
	2	Stale
	3	Normal        --> Nothing returned
	4	Warning
	5	Failed
	6	Misconfigured
	7	Disconnected
	11	Unacknowledged
	12	Acknowledged

	The API does not allow combinations of these filters.
	1-7 are reflected in the notifstate-property.
	11 and 12 relate to the properties  numberofactivenotification and numberofacknowledgednotification. 

	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false,	#Existing Customer ID
               #ValueFromPipeline = $true,
               ValueFromPipelineByPropertyName = $true,
               Position = 0,
               HelpMessage = 'Existing Customer ID')]
		[Int]$CustomerID,

		[Parameter(Mandatory=$false,	#Text for filtering
			ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 1,
			HelpMessage = 'Text for filtering')]
		[String]$IssueSearchBy = "",

		[Parameter(Mandatory=$false,	#Status Code for filtering
			ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 2,
			HelpMessage = 'Status Code for filtering')]
		[Int]$IssueStatus = 0,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
		If (!$CustomerID){
			Write-Host "No CustomerID specified."
			If (!$NcSession.DefaultCustomerID){
				Break
			}
			$CustomerID = $NcSession.DefaultCustomerID
			Write-Host ("Using current default CustomerID {0} for NCActiveIssuesList." -f $CustomerID)
		}
	}
	Process{
		$ReturnData = $NcSession.ActiveIssuesList($CustomerID, $IssueSearchBy, $IssueStatus)
	}
	End{
		$ReturnData |
		## Alphabetical Columnnames
		Select-Object ($ReturnData|Get-Member -type Noteproperty -ErrorAction SilentlyContinue).name -ErrorAction SilentlyContinue |
		#Sort-Object TransitionTime -Descending |
		## Put important fields in front. and Add Custom Fields
		Select-Object taskid,
					@{n="siteid"; e={$_.CustomerID}},
					CustomerName,
					DeviceID,
					DeviceName,
					DeviceClass,
					ServiceName,
					NotifState,
					@{n="notifstatetxt"; e={$NcSession.NCStatus.[int]$_.notifstate}},
					TransitionTime,
					* -ErrorAction SilentlyContinue
					# | Write-Output
	}
}

Function Get-NCJobStatusList{
	<#
	.Synopsis
	Returns the Scheduled Jobs on the CustomerID-level and below.
	
	.Description
	Returns the Scheduled Jobs on the CustomerID-level and below.
	Including Discovery Jobs
		
	If no customerID is supplied, all Jobs are returned.
	The SiteID of the devices is returned (Not CustomerID).
	
	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false,	#Existing Customer ID, leave empty for default
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Existing Customer ID')]
		[Int]$CustomerID,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
		If (!$CustomerID){
			Write-Host "No CustomerID specified."
			If (!$NcSession.DefaultCustomerID){
				Break
			}
			$CustomerID = $NcSession.DefaultCustomerID
			Write-Host ("Using current default CustomerID {0} for NCJobStatusList." -f $CustomerID)
		}
	}
	Process{
		$NcSession.JobStatusList($CustomerID)|
		Select-Object CustomerID,CustomerName,DeviceID,DeviceName,DeviceClass,JobName,ScheduledTime,* -ErrorAction SilentlyContinue |
#		Sort-Object ScheduledTime -Descending | Select-Object @{n="SiteID"; e={$_.CustomerID}},CustomerName,DeviceID,DeviceName,DeviceClass,ServiceName,TransitionTime,NotifState,* -ErrorAction SilentlyContinue |
		Write-Output
	}
	End{
	}
}

Function Get-NCDeviceStatus{
	<#
	.Synopsis
	Returns the Services for the DeviceID(s).

	.Description
	Returns the Services for the DeviceID(s).
	DeviceID(s) must be supplied, as a parameter or by PipeLine.

	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$true,		#Existing Device IDs
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Existing Device IDs')]
			[Alias("DeviceID")]
		[Array]$DeviceIDs,
		
		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}
	Process{
		ForEach($DeviceID in $DeviceIDs){
			$NcSession.DeviceGetStatus($DeviceID)|
			Select-Object deviceid,devicename,serviceid,modulename,statestatus,transitiontime,* -ErrorAction SilentlyContinue 
			#| Write-Output
		}
	}
	End{
	}
}
#EndRegion

#Region Access Control
Function Get-NCAccessGroupList{
	<#
	.Synopsis
	Returns the list of AccessGroups at the specified CustomerID level.

	.Description
	Returns the list of AccessGroups at the specified CustomerID level.

	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false,	#Existing Customer IDs
               #ValueFromPipeline = $true,
               ValueFromPipelineByPropertyName = $true,
               Position = 0,
			HelpMessage = 'Existing Customer IDs')]
			[Alias("customerid")]
		[array]$CustomerIDs,
	   		
		[Parameter(Mandatory=$false,	#Return only used AccessGroups
			HelpMessage = 'Return only used AccessGroups')]
			[Alias("UsedOnly")]
		[Switch]$Filter,

		[Parameter(Mandatory=$false,	#No Sorting of the output columns
			HelpMessage = 'No Sorting of the output columns')]
			[Alias('UnSorted')]
		[Switch]$NoSort,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
		If (!$CustomerIDs){
			Write-Host "No CustomerID specified."
			If (!$NcSession.DefaultCustomerID){
				Break
			}
			$CustomerIDs = $NcSession.DefaultCustomerID
			Write-Host ("Using current default CustomerID {0} for NCAccessGroupList." -f $CustomerIDs)
		}
	}
	Process{
		$ReturnData = @()
		ForEach($CustomerID in $customerIDs){
			#Write-Output $NcSession.AccessGroupList($CustomerID)
			$ReturnData += $NcSession.AccessGroupList($CustomerID)
			# |	Where-Object {$_.customerid -eq $Customerid}
		}
		## Return only used groups.
		If($Filter){
			$Returndata = $Returndata | Where-object {$_.usernames -ne "[]"}
		}
	}
	End{
		If($NoSort){
			$ReturnData 
			#| Write-Output
		}
		Else{
			## Alphabetical Columnnames
			$ReturnData | Select-Object ($ReturnData|Get-Member -type Noteproperty -ErrorAction SilentlyContinue).name -ErrorAction SilentlyContinue |
			## Important fields in front. ToDo: Boolean customergroup, derived from groupType.
			Select-Object groupid,grouptype,customerid,groupname,* -ErrorAction SilentlyContinue 
			#| Write-Output
		}
	}
}
Function Get-NCAccessGroupDetails{
	<#
	.Synopsis
	Returns the details of the specified (CustomerAccess) GroupID.

	.Description
	Returns the details of the specified (CustomerAccess) GroupID.

	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$true,		#Existing Group IDs
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Existing Group IDs')]
			[Alias("groupid")]
		[array]$GroupIDs,
				
		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$GroupIDs){
			Write-Host "No GroupID specified."
			Break
		}

		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}
	Process{
		$ReturnData = @()
		ForEach($GroupID in $GroupIDs){
			## Only Customer-AccessGroups. ToDo: Implement DeviceGroups (now error: 4100 Invalid parameters)
			$ReturnData += $NcSession.AccessGroupGet($GroupID)
		}
	}
	End{
		$ReturnData 
		#| Write-Output
	}
}
	
Function Get-NCUserRoleList{
<#
.Synopsis
Returns the list of Roles at the specified CustomerID level.

.Description
Returns the list of Roles at the specified CustomerID level.

#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false,	#Existing Customer IDs
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Existing Customer IDs')]
			[Alias("customerid")]
		[array]$CustomerIDs,

		[Parameter(Mandatory=$false,	#Return only used Roles
			HelpMessage = 'Return only used Roles')]
			[Alias("UsedOnly")]
		[Switch]$Filter,

		[Parameter(Mandatory=$false,	#No Sorting of the output colums
			HelpMessage = 'No Sorting of the output colums')]
			[Alias('UnSorted')]
		[Switch]$NoSort,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
		If (!$CustomerIDs){
			Write-Host "No CustomerID specified."
			If (!$NcSession.DefaultCustomerID){
				Break
			}
			$CustomerIDs = $NcSession.DefaultCustomerID
			Write-Host ("Using current default CustomerID {0} for NCUserRoleList." -f $CustomerIDs)
		}
	}
	Process{
		$Returndata = @()
		ForEach($CustomerID in $CustomerIDs){
			#Write-Output $NcSession.UserRoleList($CustomerID)
			## Customerid is not returned inside the query-result.
			$ReturnData += $NcSession.UserRoleList($CustomerID) |
							Select-Object @{n="customerid"; e={$customerid}},
										* -ErrorAction SilentlyContinue 
		}
		## All-parameter NOT provided returns only filtered results.
		If($Filter){
			$Returndata = $Returndata | Where-object {$_.usernames -ne "[]"}
		}
	}
	End{
		If($NoSort){
			$ReturnData 
			#| Write-Output
		}
		Else{
			## Alphabetical Columnnames
			$ReturnData | Select-Object ($ReturnData|Get-Member -type Noteproperty -ErrorAction SilentlyContinue).name -ErrorAction SilentlyContinue |
			## Important fields in front. ToDo: Boolean customergroup, derived from groupType.
			Select-Object roleid,readonly,customerid,rolename,* -ErrorAction SilentlyContinue 
			#| Write-Output
		}
	}
}

Function Get-NCUserRoleDetails{
	<#
	.Synopsis
	Returns the Details of the specified RoleID.

	.Description
	Returns the Details of the specified RoleID.

	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false,	#Existing Role IDs
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Existing Role IDs')]
			[Alias("roleid")]
		[array]$RoleIDs,

		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$RoleIDs){
			Write-Host "No RoleID specified."
			Break
		}
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}
	Process{
		$Returndata = @()
		ForEach($RoleID in $RoleIDs){
			#Write-Output $NcSession.UserRoleGet($RoleID)
			$ReturnData +=  $NcSession.UserRoleGet($RoleID)
		}
	}
	End{
		$ReturnData 
		#| Write-Output
	}
}
#EndRegion

#Region Tools

Function Backup-NCCustomProperties{
	<#
	.Synopsis
	Backup CustomProperties to a file. Customer or Device. WIP
	
	.Description
	Backup CustomProperties to a file. Customer or Device.
	PathName must be supplied.
	Work In Progress. Currently Customer-Data only.
	

	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$true,		#Existing Customer ID
			#ValueFromPipeline = $true,
			ValueFromPipelineByPropertyName = $true,
			Position = 0,
			HelpMessage = 'Existing Customer ID')]
			[Alias("IDs,CustomerID")]
		[array]$CustomerIDs,

		[Parameter(Mandatory=$true,		#Backup Target Path
			#ValueFromPipeline = $true,
			#ValueFromPipelineByPropertyName = $true,
			Position = 1,
			HelpMessage = 'Backup Target Path')]
			[Alias("Path")]
		[String]$BackupPath,
			
		[Parameter(Mandatory=$false,	#Existing NCentral_Connection, leave empty for default
			HelpMessage = 'Existing NCentral_Connection, leave empty for default')]
		$NcSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		
		#Valid Path / sufficient rights
		$DateID =(get-date).ToString(‘yyyyMMdd’)
		$ExportFile = ("{0}\Backup_{1}.json" -f $BackupPath,$DateId)

		## [System.IO.File]::Exists($ExportFile)
		## Test-Path $ExportFile -PathType Leaf
		If(Test-Path $ExportFile -PathType Leaf){
			Write-Warning "File already existed"
			Remove-Item -Path $ExportFile -Force
		}


		#$ReturnData = $null

		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}
	Process{
		Write-Host "Backup-NCCustomerProperties - Work in Progress"
		Write-host ("Exporting data for Customer(s) {0} to file {1}" -f ($CustomerIDs -join ","),$ExportFile)

		## Add information about the backup to the output.
		$BUHeader = @{}
		#$BUHeader.Date = $DateID
		$BUHeader.TimeStamp = get-date
		$BUHeader.Customers = ($CustomerIDs -join ",")


		## Customer-properties (Full)
		$CustomerData = Get-NCCustomerPropertyList $CustomerIDs -full

#<#
		## Device-Properties (Custom Only)
		[System.Collections.ArrayList]$DeviceData = @()
		Foreach($Customer in $CustomerData){
			$DeviceInfo = ,(Get-NCDeviceList $Customer.CustomerID | 
				Tee-Object -Variable LookupList) | 
				Get-NCDevicePropertyList |
				Select-Object deviceid,
						@{n="DeviceName" ; e= {$DID=$_.deviceid ; (@($LookUpList).Where({ $_.deviceid -eq $DID})).longname}},
						@{n="CustomerID" ; e= {$DID=$_.deviceid ; (@($LookUpList).Where({ $_.deviceid -eq $DID})).customerid}},
						@{n="LastLoggedInUser" ; e= {$DID=$_.deviceid ; (@($LookUpList).Where({ $_.deviceid -eq $DID})).lastloggedinuser}},
						* -ErrorAction SilentlyContinue

			$DeviceData += $Deviceinfo
		}
#>

		## ToDo - Filtering/Exclusion based on 
		##			-selection(array)
		##			-non-null value
		##			-customer-data only
		##		- Encoding output

		## Add data to Backup-set
		$BUHeader.CustomerData = $CustomerData
		$BUHeader.DeviceData = $DeviceData
#		$BUHeader.CustomerData = $NCSession.ConvertBase64($CustomerData,$false,$false)

		## Export Backup-set as JSON (Overwrite existing)
		($BUHeader | 
			ConvertTo-Json -depth 10).ToString() | 
			Out-File $ExportFile -NoClobber -Force

	}
	End{

		#$Returndata 
		#| Write-Output
	}
}

Function Select-NCCustomerUI{
	<#
	.Synopsis
	Returns a CustomerID from an interactive Selection-UI

	.Description
	Returns a CustomerID from an interactive Selection-UI

	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$false,	#Existing Drmm_Connection, leave empty for default
			HelpMessage = 'Existing NC_Connection, leave empty for default')]
		$NCSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}	
	Process{
		## Site Selection
		$CustomerList = Get-NCCustomerList
		$CustomerListMenu = $CustomerList | Select-object customername,
												customerid,
												@{n="ParentName";e= {$CID=$_.parentId ; (@($CustomerList).Where({$_.customerId -eq $CID})).customername}},
												parentid  | 
											Sort-Object parentname,customername

		$SelectedCustomer = $CustomerListMenu | Out-GridView -Title "Select a Customer/Site" -OutputMode Single
		If (!$SelectedCustomer){
			Write-Host "No Customer/Site Selected."
			Exit
		}
	}
	End{
		$SelectedCustomer.customerid
	}
}

Function Select-NCDeviceUI{
	<#
	.Synopsis
	Returns a DeviceID from an interactive Selection-UI for a given CustomerID

	.Description
	Returns a DeviceId from an interactive Selection-UI for a given CustomerID
	Specify CustomerID for DeviceList

	#>
	[CmdletBinding()]

	Param(
		[Parameter(Mandatory=$true,	#Existing SiteUid
			ValueFromPipeline = $true,
			Position = 0,
			HelpMessage = 'Existing CustomerID')]
		[String]$CustomerID,

		[Parameter(Mandatory=$false,	#Existing NC_Connection, leave empty for default
			HelpMessage = 'Existing NC_Connection, leave empty for default')]
		$NCSession
	)
	
	Begin{
		#check parameters. Use defaults if needed/available
		If (!$NcSession){
			If (-not (NcConnected)){
				Break
			}
			$NcSession = $Global:_NCSession
		}
	}	
	Process{
		$DeviceList = Get-NCDeviceList $CustomerID

		## Device Selection
		$DeviceListMenu = $DeviceList | Select-object longname,discoveredname,deviceclass,deviceid  #| Sort-Object longname
		$SelectedDevice = $DeviceListMenu | Out-GridView -Title "Select a Device" -OutputMode Single

		If (!$SelectedDevice){
			Write-Host "No Device Selected."
			Exit
		}
	}
	End{
		$SelectedDevice.deviceid
	}



}


#EndRegion Tools


#EndRegion PowerShell CmdLets

#Region Module management
# Best practice - Export the individual Module-commands.
## https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/export-modulemember

Export-ModuleMember -Function Get-NCHelp,
Convert-Base64,
Format-Properties,
NcConnected,
New-NCentralConnection,
Get-NCTimeOut,
Set-NCTimeOut,
Get-NCServiceOrganizationList,
Get-NCCustomerList,
Set-NCCustomerDefault,
Get-NCCustomerPropertyList,
Set-NCCustomerProperty,
Get-NCCustomerProperty,
Add-NCCustomerPropertyValue,
Remove-NCCustomerPropertyValue,
Get-NCProbeList,
Get-NCJobStatusList,
Get-NCDeviceList,
Get-NCDeviceID,
Get-NCDeviceLocal,
Get-NCDevicePropertyList,
Get-NCDevicePropertyListFilter,
Set-NCDeviceProperty,
Get-NCDeviceProperty,
Add-NCDevicePropertyValue,
Remove-NCDevicePropertyValue,
Get-NCActiveIssuesList,
Get-NCDeviceInfo,
Get-NCDeviceObject,
Get-NCDeviceStatus,
Get-NCAccessGroupList,
Get-NCAccessGroupDetails,
Get-NCUserRoleList,
Get-NCUserRoleDetails,
Backup-NCCustomProperties,
Get-NCVersion,
Select-NCCustomerUI,
Select-NCDeviceUI



Write-Debug "Module PS-NCentral loaded"

#EndRegion Module management
