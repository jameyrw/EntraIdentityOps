function Build-EntraRoleLookups {
    [CmdletBinding()]
    param (
    [Parameter(Mandatory)]
    [hashtable]$GroupRoleMapping
    )

    $lookupSets = @{}
    $totalGroups = $GroupRoleMapping.Count
    $currentGroup = 0
    foreach ($role in $GroupRoleMapping.Keys) {
        $currentGroup++
        Write-Progress -Activity "Loading group memberships" -Status "Processing $role" -PercentComplete (($currentGroup / $totalGroups) * 100)
        $currentSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $groupId = $GroupRoleMapping[$role]
        try {
            Get-MgGroupMember -All -GroupID $groupId -ErrorAction Stop | ForEach-Object {
                $upn = $_.AdditionalProperties['userPrincipalName']
                if ($upn) {
                    [void]$currentSet.Add($upn)
                }
            }
            $lookupSets[$role] = $currentSet
        } catch {
            throw "Get-MgGroupMember call failed $($_.Exception.Message)"
        }

    }
    Write-Progress -Activity "Loading group memberships" -Completed

    return $lookupSets
}
