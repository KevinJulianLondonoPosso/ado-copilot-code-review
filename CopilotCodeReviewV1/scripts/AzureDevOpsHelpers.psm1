<#
.SYNOPSIS
    Shared helper functions for Azure DevOps REST API interactions.

.DESCRIPTION
    This module provides common utility functions used across Azure DevOps PowerShell scripts:
    - Get-AuthorizationHeader: Builds auth headers for PAT or OAuth tokens
    - Invoke-AzureDevOpsApi: Centralized REST call wrapper with error handling
    - Write-Output-Line: Dual output to console and optional in-memory buffer
    - Format-DateForDisplay: Parses and formats ADO date strings

    Before calling Write-Output-Line, scripts should call Set-OutputHandling to register
    the output buffer so that file-write support works correctly.

.NOTES
    Author: Little Fort Software
    Requires: PowerShell 5.1 or later
#>

# Module-level output state used by Write-Output-Line
$script:OutputToFile = $false
$script:OutputBuilder = $null

function Set-OutputHandling {
    <#
    .SYNOPSIS
        Initializes the module-level output buffer used by Write-Output-Line.
    .PARAMETER OutputToFile
        Set to $true when output should also be written to an in-memory buffer.
    .PARAMETER Builder
        The System.Text.StringBuilder instance that Write-Output-Line should append to.
    #>
    param(
        [bool]$OutputToFile,
        [System.Text.StringBuilder]$Builder
    )
    $script:OutputToFile = $OutputToFile
    $script:OutputBuilder = $Builder
}

function Write-Output-Line {
    <#
    .SYNOPSIS
        Writes a line of text to the console and optionally to the module-level output buffer.
    #>
    param(
        [string]$Message = "",
        [string]$ForegroundColor = "White",
        [switch]$NoNewline
    )

    if ($script:OutputToFile -and $null -ne $script:OutputBuilder) {
        if ($NoNewline) {
            $script:OutputBuilder.Append($Message) | Out-Null
        }
        else {
            $script:OutputBuilder.AppendLine($Message) | Out-Null
        }
    }

    if ($NoNewline) {
        Write-Host $Message -ForegroundColor $ForegroundColor -NoNewline
    }
    else {
        Write-Host $Message -ForegroundColor $ForegroundColor
    }
}

function Get-AuthorizationHeader {
    <#
    .SYNOPSIS
        Builds an authorization header hashtable for Azure DevOps REST API calls.
    .PARAMETER Token
        The PAT or OAuth bearer token.
    .PARAMETER AuthType
        'Basic' for PAT authentication, 'Bearer' for OAuth/System.AccessToken.
    #>
    param(
        [string]$Token,
        [string]$AuthType = "Basic"
    )

    if ($AuthType -eq "Bearer") {
        return @{
            Authorization  = "Bearer $Token"
            "Content-Type" = "application/json"
        }
    }
    else {
        $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token"))
        return @{
            Authorization  = "Basic $base64Auth"
            "Content-Type" = "application/json"
        }
    }
}

function Invoke-AzureDevOpsApi {
    <#
    .SYNOPSIS
        Invokes an Azure DevOps REST API endpoint with consistent error handling.
    .PARAMETER Uri
        Full URI of the API endpoint.
    .PARAMETER Headers
        Authorization and content-type headers (from Get-AuthorizationHeader).
    .PARAMETER Method
        HTTP method. Defaults to 'Get'.
    .PARAMETER Body
        Optional request body object. Serialized to JSON automatically.
    #>
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Method = "Get",
        [object]$Body = $null
    )

    try {
        $params = @{
            Uri         = $Uri
            Headers     = $Headers
            Method      = $Method
            ErrorAction = "Stop"
        }

        if ($null -ne $Body) {
            $params.Body = $Body | ConvertTo-Json -Depth 10
        }

        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        $statusCode = $null
        $errorDetail = $null

        if ($_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode.value__
        }
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $errorDetail = $_.ErrorDetails.Message
        }

        $baseMsg = "Azure DevOps API error"
        if ($statusCode) {
            $baseMsg += " (HTTP $statusCode)"
        }
        $baseMsg += " calling $Method $Uri"

        if ($statusCode -eq 401) {
            Write-Error "$baseMsg — Authentication failed. Please verify your token is valid and has appropriate permissions. API response: $errorDetail"
        }
        elseif ($statusCode -eq 404) {
            Write-Error "$baseMsg — Resource not found. Please verify the organization, project, repository, and PR ID. API response: $errorDetail"
        }
        elseif ($statusCode -eq 400) {
            Write-Error "$baseMsg — Bad request. API response: $errorDetail"
        }
        elseif ($statusCode) {
            Write-Error "$baseMsg — API response: $errorDetail"
        }
        else {
            Write-Error "$baseMsg — $($_.Exception.Message)"
        }
        return $null
    }
}

function Format-DateForDisplay {
    <#
    .SYNOPSIS
        Parses an Azure DevOps date string and returns a human-readable local time.
    #>
    param([string]$DateString)

    if ([string]::IsNullOrEmpty($DateString)) {
        return "N/A"
    }

    try {
        $date = [DateTime]::Parse($DateString)
        return $date.ToString("yyyy-MM-dd HH:mm")
    }
    catch {
        return $DateString
    }
}

Export-ModuleMember -Function Set-OutputHandling, Write-Output-Line, Get-AuthorizationHeader, Invoke-AzureDevOpsApi, Format-DateForDisplay
