<#
.SYNOPSIS
Checks a given user identity(s) against specified role groups and returns their lifecycle status.

.DESCRIPTION
Queries the currently connected Microsoft Graph instance for the provided user identity(s) and compares them
to the provided role groups. Groups can either be specified by -GroupRoleMapping or 
with $global:EntraUserRoleDefaults.

By default, for batches of identities over 50 this cmdlet will load the contents of all role groups into memory in order to perform lookups.
For very large group memberships, be conscientious of memory utilization. This is most efficient for performing
large numbers of lookups (many users) vs a few groups.

For small batches (under 50 by default), this cmdlet will perform individual API calls in order to determine their status.

.PARAMETER Identities
The identity or list of identities that will be checked.

.PARAMETER GroupRoleMapping
The group IDs corresponding to the role groups to reference for the lookup.

.PARAMETER UseCache
Instructs the cmdlet to check for and use cached role data from previous runs.

.PARAMETER CacheExpirationMinutes
Determines the length of time between cache expirations.

.PARAMETER BatchType
Instructs the function to use a specific mode for processing identities, overriding the automatic selection logic.
This is useful for explicitly controlling performance characteristics. The valid options are:
- Large: The function pre-loads all members of all specified groups into memory first. This has a high initial startup cost but is extremely fast for checking a large number of identities.
- Small: The function checks each identity individually against the Microsoft Graph API. This has no startup cost but incurs more API calls, making it ideal for checking only a few identities.

.PARAMETER LargeBatchSize
Specifies the identity count threshold at which the function automatically switches from the 'Small' batch strategy to the 'Large' batch strategy.
This parameter is only effective when the -BatchType parameter is not used.
The default value is 50. For example, if you provide 51 identities without specifying -BatchType, the function will use the more efficient 'Large' strategy.

.PARAMETER ApiDelayMilliseconds
The delay in milliseconds applied to the queries which check for the user(s)' existence in Entra ID

.INPUTS
System.String[]
    The cmdlet accepts an array of strings (User Principal Names) directly via the -Identities
    parameter or from the pipeline. It also accepts pipeline input from objects that have
    a property named 'Identities'.

.OUTPUTS
System.Management.Automation.PSCustomObject
    For each input identity, the function outputs a PSCustomObject with properties corresponding to the 
    provided GroupRoleMapping parameter. For example, providing the following groups will result in the following object
    structure: Terminated, ActiveStaff, ActiveFaculty, Alumni

    UserPrincipalName : j.doe@contoso.com
    Terminated        : False
    ActiveStaff       : True
    ActiveFaculty     : False
    Alumni            : True

.EXAMPLE
Get-EntraUserRole -Identities @('j.doe@contoso.com','a.smith@contoso.com')

This example assumes that global defaults have been set for GroupRoleMapping.

.EXAMPLE
Get-EntraUserRole -Identities 'j.doe@contoso.com' -GroupRoleMapping @{
    'Terminated' = '11111111-2222-3333-4444-555555555555'
    'ActiveStaff'     = '22222222-3333-4444-5555-666666666666' 
    'ActiveFaculty'     = '33333333-4444-5555-6666-777777777777'
    'Alumni'     = '44444444-5555-6666-7777-888888888888'
    }

This command specifies Object IDs for each expected role group, and bypasses the hardcoded defaults

.EXAMPLE
Import-Csv .\userList.csv | Select-Object -ExpandProperty UserPrincipalName | Get-EntraUserRole

Imports a csv list, extracts their UserPrincipalNames, and gets their role status.
This example assumes that global defaults have been set for GroupRoleMapping.
#>

function Get-EntraUserRole {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Identities,
        [ValidateNotNull()]
        [hashtable]$GroupRoleMapping = @{},
        [switch]$UseCache,
        [int]$CacheExpirationMinutes = 60,
        [ValidateSet("Small","Large")]
        [string]$BatchType,
        [int]$LargeBatchSize = 50,
        [int]$ApiDelayMilliseconds = 100
    )
    
    begin {
        Write-Verbose "BEGIN: Initializing Get-EntraUserRole..."
        #  Collect ALL pipeline input into a single list 
        $private:AllIdentities = [System.Collections.Generic.List[string]]::new()

        # --- Resolve Configuration and Validate Connections ---
        if (-not $PSBoundParameters.ContainsKey('GroupRoleMapping') -or $GroupRoleMapping.Count -eq 0) {
            Write-Verbose "GroupRoleMapping not provided. Looking for `$global:EntraUserRoleDefaults..."
            if ($global:EntraUserRoleDefaults) {
                $GroupRoleMapping = $global:EntraUserRoleDefaults
                Write-Verbose "Found and loaded global default configuration."
            }
            else {
                # If no parameter AND no global default, fail loudly.
                throw "The -GroupRoleMapping parameter was not provided and no default configuration was found in `$global:EntraUserRoleDefaults."
            }
        }
        
        $context = Get-MgContext -ErrorAction SilentlyContinue
        if (-not $context) { throw "Not connected to Microsoft Graph. Use Connect-MgGraph first." }
    }
    
    process {
        # Collect all input here so that we can batch properly in the END block
        # Add every identity from the pipeline into our master list.
        $private:AllIdentities.AddRange($Identities)
    }
    
    end {
        Write-Verbose "END: All pipeline input received. Processing $($private:AllIdentities.Count) unique identities..."
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        # Define context for large batch sizes
        $largeBatchMode = ($BatchType -eq "Large" -or ($private:AllIdentities.Count -gt $LargeBatchSize))
        
        # Preprocessing for Large Batch Mode
        if ($largeBatchMode) {
            # --- Pre-load Group Lookups ---
            Write-Verbose "Pre-loading group membership lookups..."
            if ($UseCache -and $script:EntraRoleCache -and 
                $script:EntraRoleCacheTime -gt (Get-Date).AddMinutes(-$CacheExpirationMinutes)) {
                $private:lookupSets = $script:EntraRoleCache
                Write-Verbose "Using cached role data."
            } else {
                # Validate groups exist before building lookups
                foreach ($role in $GroupRoleMapping.Keys) {
                    $groupId = $GroupRoleMapping[$role]
                    try { Get-MgGroup -GroupId $groupId -ErrorAction Stop > $null } catch { throw "Group not found or inaccessible: $groupId for role '$role'" }
                }
                $private:lookupSets = Build-EntraRoleLookups $GroupRoleMapping
                if ($UseCache) {
                    $script:EntraRoleCache = $lookupSets
                    $script:EntraRoleCacheTime = Get-Date
                }
            }
            $private:allRoleNames = $private:lookupSets.Keys
        }

        # --- Start outer loop: LOOK FOR MATCHING ENTRA ID OBJECT ---
        $batchSize = 5 # This is the maximum batch size allowed by the Graph API given that we have 3 filter conditions
        for ($i = 0; $i -lt $private:AllIdentities.Count; $i += $batchSize) {
            $batch = $private:AllIdentities.GetRange($i, [Math]::Min($batchSize, $private:AllIdentities.Count - $i))
            if ($batch.Count -eq 0) { continue }

            Write-Verbose "Processing batch $($i / $batchSize + 1)..."
            
            # Existence Check for the Batch
            $existingUsersLookup = @{} # Lookup table for the existence check. It contains UPN, Mail, and Proxy Addresses
            try {
                # Search UPN, primary mail, AND all proxy addresses
                $filterComponents = $batch | ForEach-Object {
                    $escapedIdentity = $_.Replace("'", "''")
                    # Note: proxyAddresses filter syntax is specific
                    "(userPrincipalName eq '$escapedIdentity' or mail eq '$escapedIdentity' or proxyAddresses/any(p:p eq '$escapedIdentity'))"
                }
                $filterString = $filterComponents | Join-String -Separator ' or '
                
                # Request all properties needed for the lookup.
                $existingUsers = Get-MgUser -Filter $filterString -Property UserPrincipalName,Mail,ProxyAddresses -ErrorAction Stop

                # Create a lookup table with the UPN, Mail, and Proxy Addresses
                if ($existingUsers) {
                    foreach ($user in $existingUsers) {
                        # Map the UserPrincipalName
                        $existingUsersLookup[$user.UserPrincipalName] = $user.UserPrincipalName
                        # Map the Mail, if it exists
                        if (-not [string]::IsNullOrEmpty($user.Mail)) {
                            $existingUsersLookup[$user.Mail] = $user.UserPrincipalName
                        }
                        # Map all Proxy Addresses
                        foreach ($proxy in $user.ProxyAddresses) {
                            # The proxy address includes "smtp:", which we need to remove for the key.
                            $cleanProxy = $proxy -replace '^smtp:', ''
                            $existingUsersLookup[$cleanProxy] = $user.UserPrincipalName
                        }
                    }
                }
            } catch {
                throw "A critical error occurred while checking user existence in Entra ID. Details: $($_.Exception.Message)"
            }

            # Throttle to avoid rate limiting
            if ($i + $batchSize -lt $private:AllIdentities.Count) {
                Start-Sleep -Milliseconds $ApiDelayMilliseconds 
            }

            # --- Start inner loop: GROUP MEMBERSHIP ---
            foreach ($Identity in $batch) {
                $outputObject = [ordered]@{
                    UserPrincipalName = $Identity
                    FoundInEntraID    = $existingUsersLookup.ContainsKey($Identity)
                }

                if ($largeBatchMode) { # --- LARGE BATCH MODE ---
                    foreach ($role in $private:allRoleNames) {
                        if ($outputObject.FoundInEntraID) {
                            $outputObject[$role] = $private:lookupSets[$role].Contains($Identity)
                        } else {
                            $outputObject[$role] = $false
                        }
                    }
                } else { # --- SMALL BATCH MODE ---
                    # User not found - no API calls needed
                    if (-not $outputObject.FoundInEntraID) {
                        Write-Verbose "User '$($Identity)' not found in Entra ID. Marking all roles as false."
                        foreach ($role in $GroupRoleMapping.Keys) {
                            $outputObject[$role] = $false
                        }
                    } else {
                        # The user was found. We must now use the *true UPN* from our lookup table for the API call.
                        $trueUpn = $existingUsersLookup[$Identity]
                        Write-Verbose "Found user '$($Identity)', resolved to true UPN: '$($trueUpn)'."

                        $maxRetries = 3
                        $retryDelaySeconds = 2
                        $operationSuccessful = $false
                        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
                            try {
                                $groupIdsToCheck = $GroupRoleMapping.Values
                                # Make the call using the correct identifier.
                                $memberOfGroupIds = Confirm-MgUserMemberGroup -UserId $trueUpn -GroupIds $groupIdsToCheck -ErrorAction Stop
                                
                                # Populate the object based on the result.
                                foreach ($role in $GroupRoleMapping.Keys) {
                                    $currentGroupId = $GroupRoleMapping[$role]
                                    $outputObject[$role] = ($memberOfGroupIds -and $memberOfGroupIds.Contains($currentGroupId))
                                }
                                
                                $operationSuccessful = $true
                                break
                            }
                            catch {
                                # Catch "ResourceNotFound" errors to avoid wasted calls
                                $errorCode = $_.ErrorDetails.Code
                                if ($errorCode -eq 'Request_BadRequest' -or $errorCode -eq 'Request_ResourceNotFound') {
                                    Write-Verbose "User '$($trueUpn)' identified as a non-group-member type or is invalid for this operation. Handled."
                                    foreach ($role in $GroupRoleMapping.Keys) { $outputObject[$role] = $false }
                                    $operationSuccessful = $true
                                    break
                                }
                                else {
                                    # Handle transient errors with retries.
                                    Write-Warning "Attempt $attempt/$maxRetries failed for '$($trueUpn)' with a transient error. Error: $($_.ErrorDetails.Message)"
                                    if ($attempt -eq $maxRetries) { Write-Error "All retry attempts failed for user '$($trueUpn)'." }
                                    else { Start-Sleep -Seconds $retryDelaySeconds }
                                }
                            }
                        }
                        # Fallback for failed retries.
                        if (-not $operationSuccessful) {
                            Write-Verbose "Could not confirm group membership for '$($trueUpn)' after all retries. Marking all roles as false."
                            foreach ($role in $GroupRoleMapping.Keys) {
                                $outputObject[$role] = $false
                            }
                        }
                    }
                }
                # --- WRITE OUTPUT ---
                Write-Output ([PSCustomObject]$outputObject)
            }
        }
        
        $stopwatch.Stop()
        Write-Verbose "Completed processing in $($stopwatch.Elapsed.TotalSeconds) seconds."
    }
}
