# EntraIdentityOps PowerShell Module v2.0

A production-ready PowerShell module for enterprise Microsoft Entra ID identity lifecycle management and role-based operations. This module efficiently determines user lifecycle states and enables sophisticated identity governance decisions based on dynamic Entra ID group memberships.

Role groups are identified by a configurable prefix (default: "Role - ") and are dynamically queried to determine the lifecycle status of users, enabling automated compliance and security workflows.

This tool is designed for both quick, interactive administrative checks and for use in complex, automated identity governance workflows suitable for enterprise environments.

## Key Features

-   **Dual-Mode Functionality:** Optimized for both quick ad-hoc lookups and large-scale automation.
-   **Dynamic Policy Engine:** Automatically discovers and categorizes hundreds of role groups based on naming conventions, eliminating the need for static configuration.
-   **Intelligent User Discovery:** Finds users by User Principal Name (UPN), primary email (`mail`), and all proxy addresses, preventing "false negatives."
-   **Adaptive Performance:** Uses optimized strategies for both large and small-scale lookups.
-   **Robust Error Handling:** Gracefully handles non-standard accounts (e.g., Shared Mailboxes) and transient API errors.
-   **Modular Design:** The three core functions are designed to be composed together, creating a clean and testable workflow.
-   **Enterprise-Ready:** Built with Microsoft's modern identity platform (Entra ID) and follows PowerShell best practices.

## Prerequisites

1.  **PowerShell:** PowerShell 5.1 or later.
2.  **Microsoft Graph PowerShell SDK:** The module must be installed.

```powershell
# Install the module if you don't have it
Install-Module Microsoft.Graph -Scope CurrentUser
```

3.  **Graph API Permissions:** You must be connected to Microsoft Graph with an account or service principal that has the following permissions:
    *   `User.Read.All` (to find users by all identifiers)
    *   `GroupMember.Read.All` (to check memberships and build caches)
    *   `Group.Read.All` (to discover and validate groups)

    Connect using a command like the following before running the script:

```powershell
Connect-MgGraph -Scopes "User.Read.All", "GroupMember.Read.All", "Group.Read.All"
```

## Installation

1.  Clone or download this repository to your local machine.
2.  Import the module into your session:

```powershell
Import-Module -Name "C:\path\to\EntraIdentityOps\EntraIdentityOps.psd1"
```

3.  **Recommended:** Place the module in a standard PowerShell module path for automatic loading:
    - User scope: `$HOME\Documents\PowerShell\Modules\EntraIdentityOps\`
    - System scope: `C:\Program Files\PowerShell\Modules\EntraIdentityOps\`

## Ad-Hoc Lookups

This is the simplest way to use the module for day-to-day administrative tasks. The `Get-EntraUserRole` function is a powerful standalone tool for quickly checking a few users against a known set of groups.

### Step 1: Configure Global Defaults (Recommended)

For ease of use, add a default group mapping to your PowerShell profile (`$PROFILE`).

```powershell
# In your PowerShell profile ($PROFILE)
$global:EntraUserRoleDefaults = @{
    'Role - Terminated'           = '11111111-2222-3333-4444-555555555555'
    'Role - Active - Staff'       = '22222222-3333-4444-5555-666666666666'
    'Role - Active - Faculty'     = '33333333-4444-5555-6666-777777777777'
}
```

### Step 2: Run the command

Check a single user.

```powershell
Get-EntraUserRole -Identity 'j.doe@contoso.com'
```

The output will be a rich object detailing their status:

```powershell
UserPrincipalName          : j.doe@contoso.onmicrosoft.com
InputIdentity              : j.doe@contoso.com
FoundInEntraID             : True
Role-Terminated            : False
Role-Active-Staff          : True
Role-Active-Faculty        : False
```

## Lifecycle Automation

The module is designed to use a three-stage architecture that separates bulk data gathering from nuanced policy decisions. This makes the system more accurate, performant, and maintainable.

1.  **Stage 1: Bulk Triage (`Get-EntraUserRole`)**
    -   A high-speed utility that scans thousands of users against a *small, critical list* of role groups. It efficiently finds users who are either not in Entra ID or are in a known "terminated" state.

2.  **Stage 2: Policy Discovery (`Resolve-EntraRoleGroup`)**
    -   A dynamic discovery engine that queries Entra ID to find *all* groups that match your organization's naming convention for "active" roles. This creates a full, up-to-date policy without manual configuration.

3.  **Stage 3: Final Decision (`Compare-EntraUserRole`)**
    -   A "surgical strike" tool that takes the small list of at-risk users from the triage stage. For each one, it performs a targeted API call to see if they belong to *any* of the active groups discovered in the policy stage, preventing incorrect deactivations.

## Recommended Workflow: A Complete Example

This example demonstrates how to use the three functions together to generate a definitive list of users to deactivate.

### Step 1: Discover the Full Role Policy

First, use `Resolve-EntraRoleGroup` to dynamically find all relevant "Active" and "Deprovisioning" groups based on keywords in their names.

```powershell
# Define the keywords that identify your group types
$activeKeywords = "Active"
$deprovisionKeywords = @("Terminated", "Former")

# This one call discovers all matching groups
$policy = Resolve-EntraRoleGroup -ActiveKeywords $activeKeywords -DeprovisionKeywords $deprovisionKeywords
```
The `$policy` object now contains two hashtables: `$policy.ActiveGroups` and `$policy.DeprovisionGroups`.

### Step 2: Perform the Initial Triage

Next, use `Get-EntraUserRole` to perform a high-speed check of your entire user list against **only the critical deprovisioning groups**.

```powershell
# $allUserIdentities is your list of users from your source system
# We use the deprovisioning map from our discovered policy.
$triageMap = $policy.DeprovisionGroups

# This efficiently checks all users against the few critical groups
$initialStatus = Get-EntraUserRole -Identities $allUserIdentities -GroupRoleMapping $triageMap
```

### Step 3: Make the Final Decision

Finally, use `Compare-EntraUserRole` to get the definitive list. It takes the at-risk users from the triage and checks them against the full list of active groups from the policy.

```powershell
# This function performs the "surgical strike" checks and returns the final list
$usersToDeactivate = Compare-EntraUserRole -InitialStatus $initialStatus -Policy $policy
```

The `$usersToDeactivate` variable now contains a highly accurate list of user objects that are confirmed for deactivation.

## Functions

This module exports three primary functions:

### `Get-EntraUserRole`
The high-speed "Triage" tool. Its purpose is to efficiently check a large number of users against a *small, well-defined* set of groups. It features intelligent user discovery and adaptive performance modes.

### `Resolve-EntraRoleGroup`
The "Policy Discovery" engine. Its purpose is to query Entra ID and dynamically build a complete and categorized map of all groups that are part of your role policy, based on naming conventions.

### `Compare-EntraUserRole`
The "Decision Engine." It takes the output from the other two functions and applies the final business logic (Trigger vs. Override) to produce a definitive, actionable list of users to be disabled.

### Internal Functions
*   **`Build-EntraRoleLookups`**: A helper function used by `Get-EntraUserRole` in its Large Batch Mode to build the in-memory cache. Not intended for direct use.

## Use Cases

- **Identity Lifecycle Management**: Automate user provisioning and deprovisioning workflows based on role group memberships
- **Compliance Auditing**: Quickly identify users with inappropriate role assignments or orphaned accounts
- **Access Reviews**: Generate reports for periodic access certification processes
- **Security Operations**: Rapidly assess user access patterns during security incidents
- **HR Integration**: Sync organizational role changes with identity platform assignments

## Architecture Highlights

- **Graph API Optimization**: Intelligent batching and caching strategies minimize API calls
- **Pipeline Support**: Full PowerShell pipeline integration for composability
- **Error Resilience**: Automatic retry logic with exponential backoff for transient failures
- **Memory Efficiency**: Adaptive algorithms switch between in-memory and API-driven modes based on workload
- **Audit Trail**: Comprehensive verbose logging for compliance and troubleshooting

## Target Audience

This module is designed for:
- **Systems Engineers** managing enterprise identity infrastructure
- **Platform Engineers** building identity automation pipelines
- **Identity Governance Teams** implementing lifecycle workflows
- **Security Operations** conducting access reviews and compliance audits

## Technical Details

- **Language**: PowerShell 5.1+
- **Dependencies**: Microsoft.Graph.Authentication, Microsoft.Graph.Users
- **API**: Microsoft Graph (Entra ID)
- **Architecture**: Modular, pipeline-friendly design
- **Testing**: Suitable for unit and integration testing frameworks

## Contributing

This is a portfolio project showcasing enterprise-grade PowerShell development practices. Feedback and suggestions are welcome.

## License

Copyright (c) 2025. All rights reserved.
