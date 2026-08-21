<#
.SYNOPSIS
Enriches user status objects with a final deactivation decision and the reason for it.

.DESCRIPTION
This function is the final decision engine. It iterates through a list of triaged user statuses, applies the full deactivation policy (Trigger vs. Override), and adds two new properties to each object:
- FinalDecision: ('KEEP' or 'DISABLE')
- DecisionReason: (A human-readable explanation for the decision)
It performs targeted API calls only for at-risk users, making it highly efficient. The output is a complete, auditable record of every user processed.

.PARAMETER InitialStatus
An array of user status objects from a preliminary `Get-EntraUserRole` call.

.PARAMETER Policy
The policy object from `Resolve-EntraRoleGroup`.

.PARAMETER ApiDelayMilliseconds
The delay in milliseconds between API calls

.OUTPUTS
[PSCustomObject[]]
    The original array of user status objects, with 'FinalDecision' and 'DecisionReason' properties added to each.

.EXAMPLE
# Prerequisite: You have already run Get-EntraUserRole and Resolve-EntraRoleGroup
# $initialStatus = Get-EntraUserRole -Identities $userList -GroupRoleMapping $deprovisionMap
# $policy = Resolve-EntraRoleGroup -ActiveKeywords "Staff" -DeprovisionKeywords "Terminated"

# Now, get the final list of users to deactivate
$usersToDisable = Compare-EntraUserRole -InitialStatus $initialStatus -Policy $policy

# The $usersToDisable variable now contains only the user objects that should be acted upon, with additional properties explaining the decision.
#>
function Compare-EntraUserRole {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject[]]$InitialStatus,
        [Parameter(Mandatory)]
        [PSCustomObject]$Policy,
        [int]$ApiDelayMilliseconds = 100
    )

    Write-Verbose "Applying final policy to $($InitialStatus.Count) user statuses..."
    
    $deprovisionRoleNames = $Policy.DeprovisionGroups.Keys
    $activeGroupIds = $Policy.ActiveGroups.Values
    
    # Create a reverse lookup map to get group names from IDs for better logging
    $activeGroupIdToNameMap = @{}
    $Policy.ActiveGroups.GetEnumerator() | ForEach-Object { $activeGroupIdToNameMap[$_.Value] = $_.Name }
    # Process each user and enrich their object
    $finalReport = foreach ($user in $InitialStatus) {
        $upn = $user.UserPrincipalName
        
        # --- Default State ---
        $decision = "KEEP"
        $reason = "No deprovisioning trigger met."

        # --- Condition 1: Check for a Deprovisioning Trigger ---
        $isMarkedForDeprovision = $false
        if (-not $user.FoundInEntraID) {
            $isMarkedForDeprovision = $true
            $decision = "DISABLE"
            $reason = "User not found in Entra ID."
        } else {
            foreach ($role in $deprovisionRoleNames) {
                if ($user.PSObject.Properties[$role] -and $user.$role -eq $true) {
                    $isMarkedForDeprovision = $true
                    $reason = "User is a member of deprovisioning group: '$role'."
                    break
                }
            }
        }

        # --- Condition 2: If triggered, check for an Active Override ---
        if ($isMarkedForDeprovision -and $user.FoundInEntraID) {
            try {
                Start-Sleep -Milliseconds $ApiDelayMilliseconds
                Write-Verbose "Performing final confirmation on deprovision candidate: $($user.UserPrincipalName)"
                $overrideGroupIds = @(Confirm-MgUserMemberGroup -UserId $upn -GroupIds $activeGroupIds -ErrorAction Stop)

                if ($overrideGroupIds) {
                    # Override found! The decision remains "KEEP".
                    $overrideGroupName = $activeGroupIdToNameMap[$overrideGroupIds[0]] # Get the name of the first override group
                    $reason = "Deprovision trigger met, but user has an active override in group: '$overrideGroupName'."
                    Write-Verbose "Override discovered for $($user.UserPrincipalName) : $($overrideGroupName)"
                } else {
                    # No override found. The decision is now "DISABLE".
                    $decision = "DISABLE"
                    # The reason is already set from the trigger check.
                }
            }
            catch {
                # On any error, we fail safe and assume no override, but log it.
                $decision = "DISABLE"
                $reason = "Deprovision trigger met, and an error occurred while checking for active overrides: $($_.ErrorDetails.Message)"
                Write-Warning "Error checking active roles for '$upn'. Assuming no override."
            }
        }

        # Add the new properties to the user object and pass it down the pipeline
        $user | Add-Member -NotePropertyName "FinalDecision" -NotePropertyValue $decision -PassThru -Force |
                Add-Member -NotePropertyName "DecisionReason" -NotePropertyValue $reason -PassThru -Force
    }
    
    return $finalReport
}
