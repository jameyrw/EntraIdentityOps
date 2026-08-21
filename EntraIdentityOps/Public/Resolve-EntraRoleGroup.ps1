<#
.SYNOPSIS
Discovers and categorizes Entra ID groups based on naming conventions and keywords.
.DESCRIPTION
This function queries Microsoft Graph to find all groups that match a specific naming prefix (e.g., "Role - "). It then categorizes these discovered groups into 'Active' and 'Deprovision' types based on keywords found in their display names.

The primary purpose is to dynamically generate a complete "policy" of which groups should be considered active roles that prevent user deactivation versus roles that trigger deactivation. This removes the need to manually maintain a static list of hundreds of group IDs.

The function is highly efficient, using a single, server-side OData filter to retrieve only the relevant groups from Entra ID.
.PARAMETER ActiveKeywords
An array of strings. If any of these keywords are found in a discovered group's display name, that group will be categorized as 'Active'.
Example: @("Staff", "Faculty", "Employee")

.PARAMETER DeprovisionKeywords
An array of strings. If any of these keywords are found in a discovered group's display name, that group will be categorized as 'Deprovision'. This check takes priority over ActiveKeywords.
Example: @("Terminated", "Former Employee")

.PARAMETER RolePrefix
The common string that the display name of all target role groups starts with. This is used to build the initial `startsWith` filter for the API query. The default is "Role - ".

.OUTPUTS
System.Management.Automation.PSCustomObject
    The function outputs a single PSCustomObject containing two hashtable properties: 'ActiveGroups' and 'DeprovisionGroups'.
    Each hashtable is a map where the key is the Group ID and the value is a formatted Role Name.

    Example Output Structure:
    
    ActiveGroups      : @{
        '11111111-2222-3333-4444-555555555555' = 'ActiveStaff';
        '22222222-3333-4444-5555-666666666666' = 'ActiveFaculty'
    }
    DeprovisionGroups : @{
        '33333333-4444-5555-6666-777777777777' = 'Terminated';
        '44444444-5555-6666-7777-888888888888' = 'FormerEmployee'
    }

.EXAMPLE
# Discover all groups starting with "Role - " and categorize them.
# Groups with "Staff" or "Faculty" in the name are 'Active'.
# Groups with "Terminated" in the name are 'Deprovision'.
Resolve-EntraRoleGroup -ActiveKeywords "Staff", "Faculty" -DeprovisionKeywords "Terminated"

.EXAMPLE
# Discover groups using a custom prefix and keywords.
Resolve-EntraRoleGroup -RolePrefix "Lifecycle - " -ActiveKeywords "Employee" -DeprovisionKeywords "Leaver"

.NOTES
This function requires an active connection to Microsoft Graph with 'Group.Read.All' permissions. Use `Connect-MgGraph` before calling this function.
It is designed to be the "policy engine" for a larger lifecycle process, providing the necessary configuration for downstream comparison functions.
#>
function Resolve-EntraRoleGroup {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string[]]$ActiveKeywords = @(),
        [string[]]$DeprovisionKeywords = @(),
        [string]$RolePrefix = "Role - "
    )

    begin {
        Write-Verbose "BEGIN: Initializing Resolve-EntraRoleGroup..."
        $context = Get-MgContext -ErrorAction SilentlyContinue
        if (-not $context) { throw "Not connected to Microsoft Graph. Use Connect-MgGraph first." }
    }

    process {
        # This function does not process pipeline input.
    }

    end {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        # --- Execute the Server-Side Query ---
        $initialFilter = "startsWith(displayName, '$RolePrefix')"
        Write-Verbose "Using initial Graph API Filter: $initialFilter"
        try {
            $allPrefixedGroups = Get-MgGroup -All -Filter $initialFilter -Property Id, DisplayName
        }
        catch {
            throw "Failed to query for initial role groups. Please check your filter and Graph API permissions. Error: $($_.Exception.Message)"
        }
        Write-Verbose "Discovered $($allPrefixedGroups.Count) groups with the specified prefix."

        # ---  Perform Client-Side Filtering ---
        # Now we filter the returned results locally using PowerShell's more flexible operators.
        $allKeywords = $ActiveKeywords + $DeprovisionKeywords
        if ($allKeywords.Count -eq 0) {
            throw "ERROR: No ActiveKeywords or DeprovisionKeywords were provided."
        }
        
        # Filter the results in memory
        $discoveredGroups = $allPrefixedGroups | Where-Object {
            $groupDisplayName = $_.DisplayName
            foreach ($keyword in $allKeywords) {
                if ($groupDisplayName -like "*$keyword*") {
                    return $true # Found a keyword match, so include this group.
                }
            }
            return $false # No keyword matched, so exclude this group.
        }
        
        Write-Verbose "Filtered down to $($discoveredGroups.Count) groups matching keywords."

        # --- Build the Output Hashtables ---
        $activeGroupMap = @{}
        $deprovisionGroupMap = @{}

        foreach ($group in $discoveredGroups) {
            $roleName = $group.DisplayName
            
            $isDeprovision = $false
            foreach ($keyword in $DeprovisionKeywords) {
                if ($group.DisplayName -like "*$keyword*") {
                    $deprovisionGroupMap[$roleName] = $group.Id
                    $isDeprovision = $true
                    break
                }
            }
            
            if (-not $isDeprovision) {
                # Because our client-side filter only included groups that match *any* keyword,
                # if it wasn't a deprovisioning one, it must be an active one.
                $activeGroupMap[$roleName] = $group.Id
            }
        }

        # --- Return the Final Object ---
        $outputObject = [PSCustomObject]@{
            ActiveGroups      = $activeGroupMap
            DeprovisionGroups = $deprovisionGroupMap
        }
        Write-Output $outputObject

        $stopwatch.Stop()
        Write-Verbose "Completed group resolution in $($stopwatch.Elapsed.TotalSeconds) seconds."
    }
}
