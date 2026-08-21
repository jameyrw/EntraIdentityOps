@{
    # Module manifest
    ModuleVersion = '2.0.0'
    GUID = '9e9aed64-803d-4b7b-bf79-b502b8cffd68'
    Author = 'Jamey Walker'
    CompanyName = 'Personal Portfolio'
    Copyright = '(c) 2025. All rights reserved.'
    Description = 'Enterprise-grade PowerShell module for Microsoft Entra ID identity lifecycle management and role-based user operations'
    
    # Requirements
    PowerShellVersion = '5.1'
    RequiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Users', 'Microsoft.Graph.Groups')
    
    # Exports
    FunctionsToExport = @('Get-EntraUserRole','Resolve-EntraRoleGroup','Compare-EntraUserRole')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    
    # Root Module
    ModuleToProcess = 'EntraIdentityOps.psm1'

    # Metadata
    PrivateData = @{
        PSData = @{
            Tags = @('Azure', 'EntraID', 'Identity', 'Lifecycle', 'IdentityGovernance', 'EnterpriseIT')
            ProjectUri = 'https://github.com/jameywalker/EntraIdentityOps'
        }
    }
}
