<#
.SYNOPSIS
    Posts a comment to a pull request in Azure DevOps.

.DESCRIPTION
    This script uses the Azure DevOps REST API to add a comment to a pull request.
    It can either create a new comment thread or reply to an existing thread.
    Supports both general PR-level comments and file-specific inline comments.

    Connection parameters (Token, CollectionUri, Project, Repository, Id) default to
    environment variables set by the pipeline task, so the script can be called with
    only the -Comment (and optional formatting) parameters when running inside the
    Copilot review workflow.

.PARAMETER Token
    Optional. Authentication token for Azure DevOps. Defaults to AZUREDEVOPS_TOKEN env var.

.PARAMETER AuthType
    Optional. The type of authentication to use. Valid values: 'Basic' (for PAT) or 'Bearer' (for OAuth/System.AccessToken).
    Defaults to AZUREDEVOPS_AUTH_TYPE env var, or 'Basic' if not set.

.PARAMETER CollectionUri
    Optional. The Azure DevOps collection URI. Defaults to AZUREDEVOPS_COLLECTION_URI env var.

.PARAMETER Project
    Optional. The Azure DevOps project name. Defaults to PROJECT env var.

.PARAMETER Repository
    Optional. The repository name. Defaults to REPOSITORY env var.

.PARAMETER Id
    Optional. The pull request ID to comment on. Defaults to PRID env var.

.PARAMETER Comment
    Required. The comment text to post. Supports markdown formatting.

.PARAMETER ThreadId
    Optional. The ID of an existing thread to reply to. If not specified, a new thread is created.

.PARAMETER Status
    Optional. The status for a new thread. Valid values: Active, Fixed, WontFix, Closed, Pending.
    Default is 'Active'. Only applies when creating a new thread (not replying).

.PARAMETER FilePath
    Optional. File path for inline comment (e.g., '/src/MyProject/Program.cs').
    When provided with StartLine, creates an inline comment on the specified file.
    Path will be normalized to use forward slashes with a leading slash.

.PARAMETER StartLine
    Optional. Starting line number for inline comment (1-based, references the right/changed side of the diff).
    Required when FilePath is provided for inline comments.

.PARAMETER EndLine
    Optional. Ending line number for inline comment. Defaults to StartLine if not provided.

.PARAMETER IterationId
    Optional. Pull request iteration ID for inline comments. Defaults to ITERATION_ID env var.
    Helps anchor the comment to the correct diff version.

.EXAMPLE
    .\Add-AzureDevOpsPRComment.ps1 -Comment "This looks good!" -Status 'Closed'
    Posts a general comment using connection details from environment variables.

.EXAMPLE
    .\Add-AzureDevOpsPRComment.ps1 -Comment "Consider async" -Status 'Active' -FilePath '/src/Program.cs' -StartLine 42
    Creates an inline comment using env var connection details.

.EXAMPLE
    .\Add-AzureDevOpsPRComment.ps1 -Token "your-pat" -CollectionUri "https://dev.azure.com/myorg" -Project "myproject" -Repository "myrepo" -Id 123 -Comment "This looks good!"
    Creates a new comment thread with explicit connection parameters.

.EXAMPLE
    .\Add-AzureDevOpsPRComment.ps1 -Token "your-pat" -CollectionUri "https://dev.azure.com/myorg" -Project "myproject" -Repository "myrepo" -Id 123 -Comment "Refactor this" -FilePath "/src/Program.cs" -StartLine 42 -EndLine 50 -IterationId 3
    Creates an inline comment spanning lines 42-50, anchored to iteration 3 of the PR.

.NOTES
    Author: Little Fort Software
    Date: December 2025
    Requires: PowerShell 5.1 or later

    Environment Variables Used (when explicit parameters are not supplied):
    - AZUREDEVOPS_TOKEN: Authentication token (PAT or OAuth)
    - AZUREDEVOPS_AUTH_TYPE: 'Basic' for PAT, 'Bearer' for OAuth
    - AZUREDEVOPS_COLLECTION_URI: Azure DevOps collection URI
    - PROJECT: Azure DevOps project name
    - REPOSITORY: Repository name
    - PRID: Pull request ID
    - ITERATION_ID: (Optional) PR iteration ID for inline comments

    If an inline comment fails (e.g., line no longer exists in the diff), the script will
    automatically fall back to posting a generic PR comment with the file path and line
    information appended to the comment text.

    Note: Parameter default values that reference environment variables ($env:*) are
    evaluated each time the script is invoked (not at module/session load time), so they
    correctly pick up the current environment state when called.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Authentication token for Azure DevOps (PAT or OAuth token). Defaults to AZUREDEVOPS_TOKEN env var.")]
    [string]$Token = $env:AZUREDEVOPS_TOKEN,

    [Parameter(Mandatory = $false, HelpMessage = "Authentication type: 'Basic' for PAT, 'Bearer' for OAuth")]
    [ValidateSet("Basic", "Bearer")]
    [string]$AuthType = $(if ($env:AZUREDEVOPS_AUTH_TYPE) { $env:AZUREDEVOPS_AUTH_TYPE } else { "Basic" }),

    [Parameter(Mandatory = $false, HelpMessage = "Azure DevOps collection URI. Defaults to AZUREDEVOPS_COLLECTION_URI env var.")]
    [string]$CollectionUri = $env:AZUREDEVOPS_COLLECTION_URI,

    [Parameter(Mandatory = $false, HelpMessage = "Azure DevOps project name. Defaults to PROJECT env var.")]
    [string]$Project = $env:PROJECT,

    [Parameter(Mandatory = $false, HelpMessage = "Repository name. Defaults to REPOSITORY env var.")]
    [string]$Repository = $env:REPOSITORY,

    [Parameter(Mandatory = $false, HelpMessage = "Pull request ID. Defaults to PRID env var.")]
    [string]$Id = $env:PRID,

    [Parameter(Mandatory = $true, HelpMessage = "Comment text to post")]
    [ValidateNotNullOrEmpty()]
    [string]$Comment,

    [Parameter(Mandatory = $false, HelpMessage = "Existing thread ID to reply to")]
    [int]$ThreadId,

    [Parameter(Mandatory = $false, HelpMessage = "Status for new thread")]
    [ValidateSet("Active", "Fixed", "WontFix", "Closed", "Pending")]
    [string]$Status = "Active",

    [Parameter(Mandatory = $false, HelpMessage = "File path for inline comment (e.g., '/src/MyProject/Program.cs')")]
    [string]$FilePath,

    [Parameter(Mandatory = $false, HelpMessage = "Starting line number for inline comment")]
    [int]$StartLine,

    [Parameter(Mandatory = $false, HelpMessage = "Ending line number for inline comment")]
    [int]$EndLine,

    [Parameter(Mandatory = $false, HelpMessage = "Pull request iteration ID for inline comments")]
    [int]$IterationId = $(if ($env:ITERATION_ID) { [int]$env:ITERATION_ID } else { 0 })
)

# Validate required connection parameters (may come from env vars or explicit args)
$missing = @()
if ([string]::IsNullOrEmpty($Token)) { $missing += 'Token (or AZUREDEVOPS_TOKEN env var)' }
if ([string]::IsNullOrEmpty($CollectionUri)) { $missing += 'CollectionUri (or AZUREDEVOPS_COLLECTION_URI env var)' }
if ([string]::IsNullOrEmpty($Project)) { $missing += 'Project (or PROJECT env var)' }
if ([string]::IsNullOrEmpty($Repository)) { $missing += 'Repository (or REPOSITORY env var)' }
if ([string]::IsNullOrEmpty($Id)) { $missing += 'Id (or PRID env var)' }
if ($missing.Count -gt 0) {
    Write-Error "Add-AzureDevOpsPRComment: Missing required parameter(s): $($missing -join ', ')"
    exit 1
}

$IdInt = [int]$Id
if ($IdInt -le 0) {
    Write-Error "Add-AzureDevOpsPRComment: Pull request ID must be a positive integer. Got: $Id"
    exit 1
}

Write-Host "Posting comment with thread status: $Status" -ForegroundColor DarkGray
Import-Module "$PSScriptRoot/AzureDevOpsHelpers.psm1" -Force

#region Helper Functions

function Get-ThreadStatusValue {
    param([string]$StatusName)
    
    switch ($StatusName) {
        "Active"   { return 1 }
        "Fixed"    { return 2 }
        "WontFix"  { return 3 }
        "Closed"   { return 4 }
        "Pending"  { return 5 }
        default    { return 1 }
    }
}

function Format-AzureDevOpsFilePath {
    param([string]$Path)
    
    # Normalize path separators to forward slashes
    $normalized = $Path -replace '\\', '/'
    
    # Ensure path starts with a forward slash
    if (-not $normalized.StartsWith('/')) {
        $normalized = '/' + $normalized
    }
    
    return $normalized
}

#endregion

#region Main Logic

$headers = Get-AuthorizationHeader -Token $Token -AuthType $AuthType
$baseUrl = "$CollectionUri/$Project/_apis/git/repositories/$Repository/pullrequests/$Id"
$apiVersion = "api-version=7.1"

# First, verify the PR exists
Write-Host "`nVerifying pull request #$Id exists..." -ForegroundColor Cyan
$prUrl = "$baseUrl`?$apiVersion"
$pr = Invoke-AzureDevOpsApi -Uri $prUrl -Headers $headers

if ($null -eq $pr) {
    Write-Error "Could not find pull request #$Id in repository '$Repository'."
    exit 1
}

Write-Host "Found PR: $($pr.title)" -ForegroundColor Green

if ($ThreadId -gt 0) {
    # Reply to existing thread
    Write-Host "`nReplying to thread #$ThreadId..." -ForegroundColor Cyan
    
    # Verify the thread exists
    $threadUrl = "$baseUrl/threads/$ThreadId`?$apiVersion"
    $existingThread = Invoke-AzureDevOpsApi -Uri $threadUrl -Headers $headers
    
    if ($null -eq $existingThread) {
        Write-Error "Could not find thread #$ThreadId on pull request #$Id."
        exit 1
    }
    
    # Post reply to the thread
    $commentsUrl = "$baseUrl/threads/$ThreadId/comments?$apiVersion"
    $body = @{
        content       = $Comment
        parentCommentId = 0
        commentType   = 1  # Text comment
    }
    
    $result = Invoke-AzureDevOpsApi -Uri $commentsUrl -Headers $headers -Method "Post" -Body $body
    
    if ($null -ne $result) {
        Write-Host "`n" + ("=" * 60) -ForegroundColor DarkGray
        Write-Host "COMMENT POSTED SUCCESSFULLY" -ForegroundColor Green
        Write-Host ("=" * 60) -ForegroundColor DarkGray
        Write-Host "`n  Thread ID:    #$ThreadId"
        Write-Host "  Comment ID:   #$($result.id)"
        Write-Host "  Author:       $($result.author.displayName)"
        Write-Host "  Posted:       $($result.publishedDate)"
        Write-Host "`n  Content:"
        Write-Host "  $Comment" -ForegroundColor White
        Write-Host "`n" + ("=" * 60) -ForegroundColor DarkGray
    }
}
else {
    # Create new thread
    $threadsUrl = "$baseUrl/threads?$apiVersion"
    $isInlineComment = -not [string]::IsNullOrEmpty($FilePath) -and $StartLine -gt 0
    
    # Build the base body
    $body = @{
        comments = @(
            @{
                content     = $Comment
                commentType = 1  # Text comment
            }
        )
        status   = Get-ThreadStatusValue -StatusName $Status
    }
    
    # Add threadContext for inline comments
    if ($isInlineComment) {
        $normalizedPath = Format-AzureDevOpsFilePath -Path $FilePath
        $effectiveEndLine = if ($EndLine -gt 0) { $EndLine } else { $StartLine }
        
        Write-Host "`nCreating inline comment thread on $normalizedPath (Lines $StartLine-$effectiveEndLine)..." -ForegroundColor Cyan
        
        $body.threadContext = @{
            filePath       = $normalizedPath
            rightFileStart = @{
                line   = $StartLine
                offset = 1
            }
            rightFileEnd   = @{
                line   = $effectiveEndLine
                offset = 1
            }
        }
        
        # Add iteration context if available
        if ($IterationId -gt 0) {
            $body.pullRequestThreadContext = @{
                iterationContext = @{
                    firstComparingIteration = $IterationId
                    secondComparingIteration = $IterationId
                }
            }
        }
    } else {
        Write-Host "`nCreating new comment thread..." -ForegroundColor Cyan
    }
    
    $result = $null
    $inlineCommentFailed = $false
    
    # Attempt to post the comment
    try {
        $result = Invoke-AzureDevOpsApi -Uri $threadsUrl -Headers $headers -Method "Post" -Body $body
    }
    catch {
        if ($isInlineComment) {
            $inlineCommentFailed = $true
            Write-Warning "Failed to post inline comment: $($_.Exception.Message)"
            Write-Warning "Falling back to generic PR comment with file/line information appended."
        }
        else {
            throw
        }
    }
    
    # Check if inline comment failed (result is null but was inline)
    if ($null -eq $result -and $isInlineComment -and -not $inlineCommentFailed) {
        $inlineCommentFailed = $true
        Write-Warning "Inline comment API returned no result. Falling back to generic PR comment."
    }
    
    # Fallback to generic comment if inline failed
    if ($inlineCommentFailed) {
        $normalizedPath = Format-AzureDevOpsFilePath -Path $FilePath
        $effectiveEndLine = if ($EndLine -gt 0) { $EndLine } else { $StartLine }
        
        # Append file/line info to the comment
        $lineInfo = if ($StartLine -eq $effectiveEndLine) { "Line $StartLine" } else { "Lines $StartLine-$effectiveEndLine" }
        $fallbackComment = $Comment + "`n`n**File:** ``$normalizedPath```n**$lineInfo**"
        
        $fallbackBody = @{
            comments = @(
                @{
                    content     = $fallbackComment
                    commentType = 1
                }
            )
            status   = Get-ThreadStatusValue -StatusName $Status
        }
        
        Write-Host "Posting generic comment with file/line information..." -ForegroundColor Yellow
        $result = Invoke-AzureDevOpsApi -Uri $threadsUrl -Headers $headers -Method "Post" -Body $fallbackBody
    }
    
    if ($null -ne $result) {
        Write-Host "`n" + ("=" * 60) -ForegroundColor DarkGray
        Write-Host "COMMENT THREAD CREATED SUCCESSFULLY" -ForegroundColor Green
        Write-Host ("=" * 60) -ForegroundColor DarkGray
        Write-Host "`n  Thread ID:    #$($result.id)"
        Write-Host "  Status:       $Status"
        if ($isInlineComment -and -not $inlineCommentFailed) {
            Write-Host "  Type:         Inline comment"
            Write-Host "  File:         $(Format-AzureDevOpsFilePath -Path $FilePath)"
            $effectiveEndLine = if ($EndLine -gt 0) { $EndLine } else { $StartLine }
            Write-Host "  Lines:        $StartLine-$effectiveEndLine"
        } else {
            Write-Host "  Type:         General comment"
        }
        Write-Host "  Comment ID:   #$($result.comments[0].id)"
        Write-Host "  Author:       $($result.comments[0].author.displayName)"
        Write-Host "  Posted:       $($result.comments[0].publishedDate)"
        Write-Host "`n  Content:"
        Write-Host "  $Comment" -ForegroundColor White
        Write-Host "`n" + ("=" * 60) -ForegroundColor DarkGray
        
        Write-Host "`nTip: Use -ThreadId $($result.id) to reply to this thread." -ForegroundColor DarkGray
    }
}

# Provide link to the PR
$webUrl = "$CollectionUri/$Project/_git/$Repository/pullrequest/$Id"
Write-Host "`nView PR: $webUrl" -ForegroundColor Cyan

#endregion
