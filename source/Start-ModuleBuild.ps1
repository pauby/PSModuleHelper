# This is taken directory from Invoke-Build .build.ps1 at https://github.com/nightroman/Invoke-Build/blob/master/.build.ps1
# will use this as a starting point
<#
.Synopsis
	Build script (https://github.com/pauby/PsTodoTxt)

.Description
	TASKS AND REQUIREMENTS
    Run tests
    Clean the project directory
#>

[CmdletBinding()]
Param (
    [String]
    $ReleaseType = 'Unknown',

    [string]
    $GitHubUsername = $env:GITHUB_USERNAME,

    [string]
    $GitHubApiKey = $env:GITHUB_API_KEY,

    [string]
    $PSGalleryApiKey = $env:PSGALLERY_API_KEY
)

# Find the build folder based on build system
$Timestamp = Get-Date -UFormat "%Y%m%d-%H%M%S"
$PSVersion = $PSVersionTable.PSVersion.Major
$TestFile = "TestResults_PS$PSVersion`_$TimeStamp.xml"
$lines = '----------------------------------------------------------------------'
$CodeCoverageThreshold = 0.8 # 80%

if($ENV:BHCommitMessage -match "!verbose") {
    #$global:VerbosePreference = 'Continue'
    $global:VerbosePreference = [System.Management.Automation.ActionPreference]::Continue
}

task Build Clean,
TestSyntax,
TestAttributeSyntax,
UpdateMetadata,
CopyModuleFilesToBuild,
MergeFunctionsToModuleScript,
UpdateModuleHelp,
MakeHTMLDocs,
CopyLicense

task Test CleanImportedModule, 
PSScriptAnalyzer,
Pester,
ValidateTestResults,
CreateCodeHealthReport

task PublishToPSGalleryOnly CleanImportedModule,
PushPSGallery, 
PushManifestBackToGitHub

task PublishGitReleaseOnly PushGitRelease,
PushManifestBackToGitHub

task PublishAll CleanImportedModule,
PushManifestBackToGitHub,
?PushGitRelease,
?PushPSGallery

Enter-Build {
    # Github links require >= tls 1.2
#    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $script:BuildInfo = Get-BuildEnvironment -ReleaseType $ReleaseType `
        -GitHubUsername $GitHubUsername -GitHubApiKey $GitHubApiKey -PSGalleryApiKey $PSGalleryApiKey
    Set-Location $BuildInfo.ProjectRootPath

    if ($VerbosePreference -ne 'SilentlyContinue') {
        $lines
        Write-Host 'Build System Environment Variables: ============================='
        Get-BuildSystemEnvironment | Convert-SensitiveData

        Write-Host 'Operating System: ==============================================='
        Get-BuildOperatingSystemDetail | Format-List

        Write-Host 'PowerShell Version: ============================================='
        Get-BuildPowerShellDetail | Format-List

        Write-Host 'Build Environment: =============================================='
        $script:BuildInfo | Convert-SensitiveData
        $lines
    }
    "`n"
}

# Synopsis: Remove build folder
task Clean CleanImportedModule, {
    try {
        Remove-BuildEnvironment -BuildInfo $BuildInfo

        $BuildInfo.BuildPath, $BuildInfo.OutputPath | ForEach-Object {
            Write-Verbose "Creating folder $_" 
            $null = New-Item $_ -ItemType Directory -Force
        }
    }
    catch {
        throw
    }
}

task CleanImportedModule {
    Write-Verbose "Unloading all versions of module '$($buildInfo.ModuleName)'." 
    Remove-Module $buildInfo.ModuleName -ErrorAction SilentlyContinue
    if ($null -ne (Get-Module -Name $buildInfo.ModuleName)) {
        throw "Removed module '$($BuildInfo.ModuleName)' but it's still loaded in the current session."
    }
}

task BleachClean {
    Remove-BuildEnvironment
}

# https://github.com/indented-automation/Indented.Build
task TestSyntax {
    $hasSyntaxErrors = $false

    Get-BuildItem -Path $BuildInfo.SourcePath -Type ShouldMerge -ExcludeClass | ForEach-Object {
        $tokens = $null
        [System.Management.Automation.Language.ParseError[]]$parseErrors = @()
        $null = [System.Management.Automation.Language.Parser]::ParseInput(
            (Get-Content $_.FullName -Raw),
            $_.FullName,
            [Ref]$tokens,
            [Ref]$parseErrors
        )
        
        if ($parseErrors.Count -gt 0) {
            $parseErrors | Write-Error

            $hasSyntaxErrors = $true
        }
    }

    if ($hasSyntaxErrors) {
        throw 'TestSyntax failed'
    }
}

# https://github.com/indented-automation/Indented.Build
task TestAttributeSyntax {
    $hasSyntaxErrors = $false
    Get-BuildItem -Path $BuildInfo.SourcePath -Type ShouldMerge -ExcludeClass | ForEach-Object {
        $tokens = $null
        [System.Management.Automation.Language.ParseError[]]$parseErrors = @()
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            (Get-Content $_.FullName -Raw),
            $_.FullName,
            [Ref]$tokens,
            [Ref]$parseErrors
        )

        # Test attribute syntax
        $attributes = $ast.FindAll( {
                param( $ast )
                
                $ast -is [System.Management.Automation.Language.AttributeAst]
            },
            $true
        )
        foreach ($attribute in $attributes) {
            if (($type = $attribute.TypeName.FullName -as [Type]) -or ($type = ('{0}Attribute' -f $attribute.TypeName.FullName) -as [Type])) {
                $propertyNames = $type.GetProperties().Name

                if ($attribute.NamedArguments.Count -gt 0) {
                    foreach ($argument in $attribute.NamedArguments) {
                        if ($argument.ArgumentName -notin $propertyNames) {
                            'Invalid property name in attribute declaration: {0}: {1} at line {2}, character {3}' -f
                            $_.Name,
                            $argument.ArgumentName,
                            $argument.Extent.StartLineNumber,
                            $argument.Extent.StartColumnNumber

                            $hasSyntaxErrors = $true
                        }
                    }
                }
            }
            else {
                'Invalid attribute declaration: {0}: {1} at line {2}, character {3}' -f
                $_.Name,
                $attribute.TypeName.FullName,
                $attribute.Extent.StartLineNumber,
                $attribute.Extent.StartColumnNumber

                $hasSyntaxErrors = $true
            }
        }
    }

    if ($hasSyntaxErrors) {
        throw 'TestAttributeSyntax failed'
    }
}

task CopyModuleFilesToBuild {
    try {
        Get-BuildItem -Path $BuildInfo.SourcePath -Type Static | `
            Copy-Item -Destination $BuildInfo.BuildPath -Recurse -Force
    }
    catch {
        throw
    }
}

task MergeFunctionsToModuleScript {
    $fileStream = [System.IO.File]::Create($BuildInfo.BuildModulePath)
    $writer = New-Object System.IO.StreamWriter($fileStream)

    $usingStatements = New-Object System.Collections.Generic.List[String]

    Get-BuildItem -Path $BuildInfo.SourcePath -Type ShouldMerge | ForEach-Object {
        $functionDefinition = Get-Content $_.FullName | ForEach-Object {
            if ($_ -match '^using (namespace|assembly)') {
                $usingStatements.Add($_)
            }
            else {
                $_.TrimEnd()
            }
        } | Out-String
        $writer.WriteLine($functionDefinition.Trim())
        $writer.WriteLine()
    }

    $writer.Close()

    $rootModule = (Get-Content $BuildInfo.BuildModulePath -Raw).Trim()
    if ($usingStatements.Count -gt 0) {
        # Add "using" statements to be start of the psm1
        $rootModule = $rootModule.Insert(0, "`r`n`r`n").Insert(
            0,
            (($usingStatements.ToArray() | Sort-Object | Get-Unique) -join "`r`n")
        )
    }
    Set-Content -Path $BuildInfo.BuildModulePath -Value $rootModule -NoNewline
}

task UpdateMetadata {
    try {
        $path = $BuildInfo.SourceManifestPath

        # Manifest Version
        Update-Metadata -Path $path -PropertyName ModuleVersion -Value $BuildInfo.ReleaseVersion -ErrorAction stop
        
        # RootModule
        if (Get-Metadata $path -PropertyName RootModule) {
            Update-Metadata $path -PropertyName RootModule -Value "$($BuildInfo.ModuleName).psm1"
        }

        # FunctionsToExport
        $functionsToExport = (Get-ChildItem (Join-Path -Path $BuildInfo.SourcePath -ChildPath 'pub*') -Filter '*.ps1' -Recurse)
        if ($functionsToExport) {
            Write-Verbose "FunctionsToExport:`nFound $($functionsToExport.count) public functions to add to manifest 'FunctionsToExport' key."
            try {
                Get-Metadata $path -PropertyName FunctionsToExport | Out-Null
            }
            catch {
                throw "FunctionsToExport key does not exists (commented out?)git status"
            }

            Write-Verbose "FunctionsToExport key exists (not commented out)"
            Update-Metadata $path -PropertyName FunctionsToExport -Value $functionsToExport.BaseName
            Write-Verbose "Added $($functionsToExport.count) functions to key."
        }

<# Leaving this here just now but it requires the module file to be built first
        # DscResourcesToExport
        $tokens = $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            (Get-Content $buildInfo.Path.RootModule -Raw),
            $buildInfo.Path.RootModule,
            [Ref]$tokens,
            [Ref]$parseErrors
        )
        $dscResourcesToExport = $ast.FindAll( {
                param ($ast)

                $ast -is [System.Management.Automation.Language.TypeDefinitionAst] -and 
                $ast.IsClass -and 
                $ast.Attributes.TypeName.FullName -contains 'DscResource'
            }, $true).Name
        if ($null -ne $dscResourcesToExport) {
            if (Get-Metadata $path -PropertyName DscResourcesToExport) {
                Update-Metadata $path -PropertyName DscResourcesToExport -Value $dscResourcesToExport
            }
        }#>

        # RequiredAssemblies
        if (Test-Path (Join-Path -Path $BuildInfo.SourcePath -ChildPath 'lib\*.dll')) {
            if (Get-Metadata $path -PropertyName RequiredAssemblies) {
                Update-Metadata $path -PropertyName RequiredAssemblies -Value (
                    (Get-Item (Join-Path -Path $BuildInfo.SourcePath -ChildPath 'lib\*.dll')).Name | ForEach-Object {
                        Join-Path -Path 'lib' -ChildPath $_
                    }
                )
            }
        }

        #ScriptsToProcess
        $scriptsToProcess = (Get-ChildItem (Join-Path -Path $BuildInfo.SourcePath -ChildPath 'script*') -Filter '*.ps1' -Recurse)
        if ($scriptsToProcess) {
            Write-Verbose "ScriptsToProcess:`nFound $($scriptsToProcess.Count) scripts to add to manifest ScriptsToProcess key."
            try {
                Get-Metadata $path -PropertyName ScriptsToProcess | Out-Null
            }
            catch {
                throw "ScriptsToProcess key does not exists (commented out?)git status"
            }

            Write-Verbose "ScriptsToProcess key exists (not commented out)"
            Update-Metadata $path -PropertyName ScriptsToProcess -Value (`
                $scriptsToProcess | ForEach-Object { 
                    if ($_.FullName -match '(?<name>script.*\\.*\.ps1)') {
                        Write-Verbose "Adding '$($matches.name)' to ScriptsToProcess"
                        $matches.name
                    } #end if
                } #end Foreach
            ) #end Update-Metadata
        } #end if

        # FormatsToProcess
        if (Test-Path (Join-Path -Path $BuildInfo.SourcePath -ChildPath '*.Format.ps1xml')) {
            if (Get-Metadata $path -PropertyName FormatsToProcess) {
                Update-Metadata $path -PropertyName FormatsToProcess `
                    -Value (Get-Item (Join-Path -Path $BuildInfo.SourcePath -ChildPath '*.Format.ps1xml')).Name
            }
        }

<# TODO: Add a way to use different licences
        # LicenseUri
        if (Test-Path (Join-Path $buildInfo.ProjectRootPath 'LICENSE')) {
            if (Get-Metadata $path -PropertyName LicenseUri) {
                Update-Metadata $path -PropertyName LicenseUri -Value 'https://opensource.org/licenses/MIT'
            }
        }
#>

        # ProjectUri
        if (Get-Metadata $path -PropertyName ProjectUri) {
            # Attempt to parse the project URI from the list of upstream repositories
            [String]$pushOrigin = (git remote -v) -like 'origin*(push)'
            if ($pushOrigin -match 'origin\s+(?<ProjectUri>https?://\S+).git') {
                Update-Metadata $path -PropertyName ProjectUri -Value $matches.ProjectUri
            }
        }
    }
    catch {
        throw
    }
}

task UpdateModuleHelp -If (Get-Module platyPS -ListAvailable) CleanImportedModule, {
    try {
        $moduleInfo = Import-Module $BuildInfo.BuildModulePath -ErrorAction Stop -PassThru
        if ($moduleInfo.ExportedCommands.Count -gt 0) {
            $moduleInfo.ExportedCommands.Keys | ForEach-Object { 
                New-MarkdownHelp -Command $_ `
                    -OutputFolder (Join-Path -Path $BuildInfo.ProjectRootPath -ChildPath 'help') -Force | Out-Null
            }

            New-ExternalHelp -Path (Join-Path -Path $BuildInfo.ProjectRootPath -ChildPath 'help') `
                -OutputPath (Join-Path -Path $BuildInfo.BuildPath -ChildPath 'en-GB') -Force | Out-Null
        }
    }
    catch {
        throw
    }
}

task MakeHTMLDocs -If { [bool](exec { pandoc.exe --help }) } {
    $names = 'README', 'CHANGELOG'
    ForEach ($name in $names) {
        $sourcePath = Join-Path -Path $BuildInfo.ProjectRootPath -ChildPath "$name.md"
        if (Test-Path $sourcePath) {
            $destPath = Join-Path -Path $BuildInfo.BuildPath -ChildPath "$name.html"
            exec { pandoc.exe --standalone --from=markdown_strict --metadata=title:$name --output=$destPath $sourcePath }
            Write-Verbose "Converted markdown file '$name.md' to '$destPath'"
        } # end if
    } # end foreach
}

task CopyLicense -If {Test-Path (Join-Path -Path $BuildInfo.ProjectRootPath -ChildPath 'LICENSE')}  {
    try {
        Copy-Item -Path (Join-Path -Path $BuildInfo.ProjectRootPath -ChildPath 'LICENSE') -Destination $BuildInfo.BuildPath
    }
    catch {
        throw
    }
}

task PSScriptAnalyzer -If (Get-Module PSScriptAnalyzer -ListAvailable) {
    try {
        Set-Location $BuildInfo.SourcePath
        'priv*', 'pub*' | Where-Object { Test-Path $_ } | ForEach-Object {
            $path = Resolve-Path (Join-Path -Path $BuildInfo.SourcePath -ChildPath $_)
            if (Test-Path $path) {
                $splat = @{
                    Path    = $path
                    Recurse = $true
                    #Verbose = $true
                }

                if (($BuildInfo.PSSASettingsPath -ne '') -and (Test-Path $BuildInfo.PSSASettingsPath -PathType Leaf)) {
                    # the settings parameter for PSScriptAnalyzer MUST be a
                    # string - see
                    # https://github.com/PowerShell/PSScriptAnalyzer/issues/914
                    $splat += @{ Settings = "$($BuildInfo.PSSASettingsPath)" } 
                }
                
                Write-Verbose "Running PSScriptAnalyzer default rules on '$path'."
                Invoke-ScriptAnalyzer @splat | ForEach-Object {
                    $_
                    $_ | Export-Csv (Join-Path -Path $BuildInfo.OutputPath -ChildPath 'psscriptanalyzer.csv') -NoTypeInformation -Append
                }
    
                # TODO:We only need to do this becasue the PSScriptAnalyzer
                # settings file does not allow CustomRulePath and
                # IncludeDefaultRules together. Once this is resolved this could
                # should be revisited.
                # https://github.com/PowerShell/PSScriptAnalyzer/issues/675
                if ($BuildInfo.PSSACustomRulesPath -ne '') {
                    $splat += @{ 
                        CustomRulePath      = "$(Join-Path -Path $BuildInfo.PSSACustomRulesPath -ChildPath '*.psd1')"
                        # TODO: This rule is here as it is throwin an exception on some code
                        #ExcludeRule         = 'Measure-ErrorActionPreference'
                    }

                    Write-Verbose "Running PSScriptAnalyzer custom rules on '$path'."
                    Invoke-ScriptAnalyzer @splat | ForEach-Object {
                        $_
                        $_ | Export-Csv (Join-Path $BuildInfo.OutputPath 'psscriptanalyzer.csv') -NoTypeInformation -Append
                    }
                }
            }
        }
    }
    catch {
        throw
    }
}

task Pester -If { Get-ChildItem -Path $BuildInfo.TestPath -Filter '*.tests.ps1' -Recurse -File } CopyModuleFilesToBuild, MergeFunctionsToModuleScript, {

    Import-Module $BuildInfo.BuildManifestPath -Global -ErrorAction Stop -Force
    $params = @{
        Script       = $BuildInfo.TestPath
        CodeCoverage = $BuildInfo.BuildModulePath
        OutputFile   = Join-Path -Path $BuildInfo.OutputPath -ChildPath "$($BuildInfo.ModuleName)-nunit.xml"
        PassThru     = $true
        Show         = if ($VerbosePreference -eq 'SilentlyContinue') { 'None' } else { 'all' }
        Strict       = $true 
    }

    $pester = Invoke-Pester @params

    $path = Join-Path -Path $BuildInfo.OutputPath -ChildPath 'pester-output.xml'
    $pester | Export-CliXml $path
}

task ValidateTestResults PSScriptAnalyzer, Pester, {
    $testsFailed = $false

    # PSScriptAnalyzer
    $path = Join-Path -Path $BuildInfo.OutputPath -ChildPath 'psscriptanalyzer.csv'
    if ((Test-Path $path) -and ($testResults = Import-Csv -Path $path)) {
        '{0} warnings were raised by PSScriptAnalyzer' -f @($testResults).Count
        $testsFailed = $true
    }
    else {
        Write-Verbose '0 warnings were raised by PSScriptAnalyzer'
    }

    # Pester tests
    $path = Join-Path -Path $BuildInfo.OutputPath -ChildPath 'pester-output.xml'
    $pester = Import-CliXml -Path $path
    if ($pester.FailedCount -gt 0) {
        '{0} of {1} Pester tests are failing' -f $pester.FailedCount, $pester.TotalCount
        $testsFailed = $true
    }
    else {
        Write-Verbose 'All Pester tests passed.'
    }

    # Pester code coverage
    [Double]$codeCoverage = $pester.CodeCoverage.NumberOfCommandsExecuted / $pester.CodeCoverage.NumberOfCommandsAnalyzed
    $pester.CodeCoverage.MissedCommands | `
        Export-Csv -Path (Join-Path -Path $BuildInfo.OutputPath -ChildPath 'CodeCoverage.csv') -NoTypeInformation

    if ($codecoverage -lt $CodeCoverageThreshold) {
        'Pester code coverage ({0:P}) is below threshold {1:P}.' -f $codeCoverage, $CodeCoverageThreshold
        $testsFailed = $true
    }

    # Solution tests
    Get-ChildItem $BuildInfo.OutputPath -Filter *.dll.xml | ForEach-Object {
        $report = [Xml](Get-Content $_.FullName -Raw)
        if ([Int]$report.'test-run'.failed -gt 0) {
            '{0} of {1} solution tests in {2} are failing' -f $report.'test-run'.failed,
            $report.'test-run'.total,
            $report.'test-run'.'test-suite'.name
            $testsFailed = $true
        }
    }

    if ($testsFailed) {
        throw 'Test result validation failed'
    }
}

task CreateCodeHealthReport -If (Get-Module PSCodeHealth -ListAvailable) {
    Import-Module -FullyQualifiedName $BuildInfo.BuildManifestPath -Global -ErrorAction Stop
    $params = @{
        Path           = $BuildInfo.BuildModulePath
        Recurse        = $true
        TestsPath      = $BuildInfo.TestPath
        HtmlReportPath = Join-Path -Path $BuildInfo.OutputPath -ChildPath "$($Buildinfo.ModuleName)-code-health.html"
    }
    Invoke-PSCodeHealth @params
}

# Synopsis: Warn about not empty git status if .git exists.
task GitStatus -If (Test-Path .git) {
    $status = exec { git status -s }
    if ($status) {
        Write-Warning "Git status: $($status -join ', ')"
    }
}

# Synopsis: Push with a version tag.
task PushGitRelease CreateBuildArtifact, {

    if ((Test-Path -Path $BuildInfo.BuildArtifactPath) -and ($BuildInfo.GithubUsername -ne '') -and ($BuildInfo.GithubApiKey -ne '')) {
        $params = @{
            Version             = $BuildInfo.ReleaseVersion
            CommitID            = $BuildInfo.RepoLastCommitHash
            ReleaseNotes        = "Release v$($BuildInfo.ReleaseVersion)"
            ArtifactPath        = $BuildInfo.BuildArtifactPath
            GitHubUsername      = $BuildInfo.GitHubUsername
            GitHubRepository    = $BuildInfo.ModuleName
            GitHubApiKey        = $BuildInfo.GithubApiKey
            Draft               = $true
        } 

        New-GitHubRelease @params
    }
    else {
        throw "Cannot push a release to GitHub - '$($BuildInfo.BuildArtifactPath)' is missing or GitHubUsername / GitHubApiKey has not been given."
    }
}

task PushPSGallery {
    if (-not $BuildInfo.PSGalleryApiKey) {
        Write-Error "Cannot push to the PowerShell Gallery as no Api Key was provided."
    }

    # get the current PS Gallery version and if it's the same as our new version then do not push it
    try {
        $psGalleryVersion = [version](Find-Module -Name $BuildInfo.ModuleName -ErrorAction Stop).Version
    }
    catch {
        Write-Warning "Cannot find a previous version of '$($BuildInfo.ModuleName)' in the PowerShell Gallery. Please push the first verison of the module manually."
    }
    if ([version]$psGalleryVersion -lt [version]$BuildInfo.ReleaseVersion) {
        Write-Verbose "Publishing version '$($BuildInfo.ReleaseVersion)' of '$($BuildInfo.ModuleName)' module to PowerShell Gallery."
        Import-Module $BuildInfo.BuildManifestPath -Global -Force
        Publish-Module -NuGetApiKey $BuildInfo.PSGalleryApiKey -Path $BuildInfo.BuildPath
    }
    else {
        throw "PowerShell Gallery Version ($psGalleryVersion) is the same or greater than our new version '($($BuildInfo.ReleaseVersion))'. Cannot publish module."
    }
}

task PushManifestBackToGitHub {
    if ($BuildInfo.GitHubUsername -eq '' -or $BuildInfo.GitHubApiKey -eq '') {
        throw 'Cannot push manifest back to Github - Username or API Key are blank.'
    }

    Set-Location $BuildInfo.ProjectRootPath
    # Resolve-Path will return the relative path that we need to match against
    # the git changed files. However the resolved path will start with '.\' so
    # we need to strip this.
    $relativePath = (Resolve-Path -Path $BuildInfo.SourceManifestPath -Relative).Substring(2).Replace('\', '/')
    # we need to use the EXACT case to 'git add <manifest>' otherwise it does
    # not work - so here we are matching with the manifest file and returning
    # the case git needs
    $manifest = Get-GitChange | Where-Object { $_ -eq $relativePath }
    if ($manifest) {
        $pushUrl = exec { git remote get-url origin --push }
        $authUrl = $pushUrl.Replace('github.com', "$($BuildInfo.GitHubUsername):$($BuildInfo.GitHubApiKey)@github.com") 
        Write-Verbose "Pushing '$manifest' back to GitHub with message 'Updated version to $($BuildInfo.ReleaseVersion)'."
        #exec { git pull }
        exec { git add $manifest }
        exec { git commit -m "Updated version to $($BuildInfo.ReleaseVersion) [skip ci]" }
        exec { git push --porcelain }   # --porcelain is required or exec detects the command as failed
    }
    else {
        Write-Warning "The source manifest '$($BuildInfo.SourceManifestPath)' has not been changed. Cannot push it back to GitHub."
    }
}

task CreateBuildArtifact {
    # create the build artifact
    $artifactName = "$($BuildInfo.ModuleName)-$($BuildInfo.ReleaseVersion).zip"
    $artifactPath = Join-Path -Path $BuildInfo.ProjectRootPath -ChildPath $artifactName
    Remove-Item -Path $artifactPath -ErrorAction SilentlyContinue

    $sourcePath = Join-Path -Path $BuildInfo.ReleaseVersion -ChildPath '*'
    Write-Verbose "Creating ZIP archive '$($BuildInfo.BuildArtifactPath)' containing '$sourcePath'."
    Compress-Archive -Path $sourcePath -DestinationPath $BuildInfo.BuildArtifactPath
}
