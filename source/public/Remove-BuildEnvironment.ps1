#.ExternalHelp PSModuleBuildHelper-help.xml
function Remove-BuildEnvironment {
    <#
    .SYNOPSIS
        Removes the folders and files created during the build process.
    .DESCRIPTION
        Removes the folders and files created during the build process.
    .EXAMPLE
        Remove-BuildEnvironment

        Removes the folders and files created during the build process.
    .NOTES
        Author  : Paul Broadwith (https://github.com/pauby)
        History : 1.0 - 16/03/18 - Initial release
    .LINK
        Get-BuildEnvironment
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    Param (
        # The build environment returned from Get-BuildEnvironment
        [Parameter(Mandatory)]
        [PSObject]$BuildInfo
    )

    if (-not $PSBoundParameters.ContainsKey('Verbose')) {
        $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference')
    }

    if ($PSCmdlet.ShouldProcess('ShouldProcess?')) {
        try {
            $rootBuildPath = Split-Path -Path $BuildInfo.BuildPath -Parent
            if (Test-Path $rootBuildPath) {
                if ($rootBuildPath -ne $BuildInfo.ProjectRootPath) {
                    Write-Verbose "Removing 'BuildOutput' folder $($BuildInfo.BuildPath)"
                    Remove-Item $rootBuildPath -Recurse -Force
                }
                else {
                    throw "Something has gone wrong as the parent of '$($BuildInfo.BuildPath)' is the project root path '$($BuildInfo.ProjectRootPath)'."
                }
            }

            if (Test-Path $BuildInfo.OutputPath) {
                Write-Verbose "Removing 'Output' folder $($BuildInfo.OutputPath)"
                Remove-Item $BuildInfo.OutputPath -Recurse -Force
            }
        }
        catch {
            throw
        }
    }
}