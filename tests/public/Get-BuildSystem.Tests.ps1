$buildOutput = Join-Path -Path $PSScriptRoot -ChildPath '..\..\releases'
$latestBuildVersion = (Get-Childitem $buildOutput | `
        Select-Object -Property @{ l = 'Name'; e = { [version]$_.Name } } | Sort-Object Name -Descending | `
        Select-Object -First 1).Name.ToString()
if ($latestBuildVersion -eq '') {
    throw 'Cannot find the latest build of the module. Did you build it beforehand?'
}
else {
    Import-Module -FullyQualifiedName (Join-Path -Path (Join-Path -Path $buildOutput -ChildPath $latestBuildVersion) `
        -ChildPath 'psmodulebuildhelper.psd1') -Force
}

Describe 'Function Testing - Get-BuildSystem' {
    Context 'Output' {
        It "should return 'Appveyor'" {
            Mock Get-Item { @{ name = 'APPVEYOR_BUILD_FOLDER' } } -ModuleName PSModuleBuildHelper

            Get-BuildSystem | Should -BeExactly 'AppVeyor'
        }

        It "should return 'Travis'" {
            Mock Get-Item { @{ name = 'TRAVIS' } } -ModuleName PSModuleBuildHelper

            Get-BuildSystem | Should -BeExactly 'Travis'
        }
    }
} 
