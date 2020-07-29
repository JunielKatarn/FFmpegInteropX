param(

    [ValidateSet('x86', 'x64', 'ARM', 'ARM64')]
    [string[]] $Platforms = ('x64', 'x86', 'ARM', 'ARM64'),

    [switch] $NoClean,

    <#
        Example values:
        14.1
        14.2
        14.16
        14.16.27023
        14.23.27820

        Note. The PlatformToolset will be inferred from this value ('v141', 'v142'...)
    #>
    [version] $VcVersion = '14.2',

    <#
        Example values:
        8.1
        10.0.15063.0
        10.0.17763.0
        10.0.18362.0
    #>
    [version] $WindowsTargetPlatformVersion = '10.0.18362.0',

    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [System.IO.DirectoryInfo] $VSInstallerFolder = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer",

    # Set the search criteria for VSWHERE.EXE.
    [string[]] $VsWhereCriteria = '-latest',

    [System.IO.FileInfo] $BashExe = "$env:windir\system32\bash.exe"
)

function Build-Platform {
    param (
        [System.IO.DirectoryInfo] $SolutionDir,
        [string] $Platform,
        [string] $Configuration,
        [version] $WindowsTargetPlatformVersion,
        [version] $VcVersion,
        [string] $PlatformToolset,
        [string] $VsLatestPath,
        [string] $BashExe = "$env:windir\system32\bash.exe"
    )

    $PSBoundParameters | Out-String

    $hostArch = ( 'x86', 'x64' )[ [System.Environment]::Is64BitOperatingSystem ]

    Write-Host "Building FFmpeg for Windows 10 apps ${Platform}..."
    Write-Host ""
    
    # Load environment from VCVARS.
    Import-Module "$VsLatestPath\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"

    Enter-VsDevShell `
        -VsInstallPath $VsLatestPath `
        -StartInPath "$PWD" `
        -DevCmdArguments "-arch=$Platform -host_arch=$hostArch -winsdk=$WindowsTargetPlatformVersion -vcvars_ver=$VcVersion -app_platform=UWP"


    # Build pkg-config fake
    MSBuild.exe $SolutionDir\Libs\PkgConfigFake\PkgConfigFake.csproj `
        /p:OutputPath="$SolutionDir\Libs\Build\" `
        /p:Configuration="Release" `
        /p:Platform=${Env:\PreferredToolArchitecture}

    if ($lastexitcode -ne 0) { throw "Failed to build PkgConfigFake." }


    New-Item -ItemType Directory -Force $SolutionDir\Libs\Build\$Platform -OutVariable libs

    ('lib', 'licenses', 'include', 'build') | ForEach-Object {
        New-Item -ItemType Directory -Force $libs\$_
    }
    
    $env:LIB += ";${libs}\lib"
    $env:INCLUDE += ";${libs}\include"
    $env:Path += ";${SolutionDir}"

    if ($NoClean) {
        $libdefs = @()
    } else {
        # Clean platform-specific build dir.
        Remove-Item -Force -Recurse $libs\build\*
        Remove-Item -Force -Recurse ${libs}\lib\*
        Remove-Item -Force -Recurse ${libs}\include\*

        # library definitions: <FolderName>, <ProjectName>, <FFmpegTargetName> 
        $libdefs = @(
            @('zlib', 'libzlib', 'zlib'),
            @('bzip2', 'libbz2', 'bz2'),
            @('libiconv', 'libiconv', 'iconv'),
            @('liblzma', 'liblzma', 'lzma'),
            @('libxml2', 'libxml2', 'libxml2')
        )
    }

    # Build all libraries
    $libdefs | ForEach-Object {
    
        $folder = $_[0];
        $project = $_[1];

        MSBuild.exe $SolutionDir\Libs\$folder\SMP\$project.vcxproj `
            /p:OutDir="$libs\build\" `
            /p:Configuration="${Configuration}WinRT" `
            /p:Platform=$Platform `
            /p:WindowsTargetPlatformVersion=$WindowsTargetPlatformVersion `
            /p:PlatformToolset=$PlatformToolset `
            /p:useenv=true

        if ($lastexitcode -ne 0) { throw "Failed to build library $project." }

        Copy-Item $libs\build\$project\include\* -Recurse $libs\include\ 
        Copy-Item $libs\build\$project\licenses\* -Recurse $libs\licenses\
        Copy-Item $libs\build\$project\lib\$Platform\${project}_winrt.lib $libs\lib\
        Copy-Item $libs\build\$project\lib\$Platform\${project}_winrt.pdb $libs\lib\
    }

    # Rename all libraries to ffmpeg target names
    $libdefs | ForEach-Object {

        $project = $_[1];
        $target = $_[2];

        Rename-Item $libs\lib\${project}_winrt.lib $libs\lib\$target.lib
        Rename-Item $libs\lib\${project}_winrt.pdb $libs\lib\$target.pdb
    }

    # Fixup libxml2 includes for ffmpeg build
    Copy-Item $libs\include\libxml2\libxml -Force -Recurse $libs\include\ 

    # Export full current PATH from environment into MSYS2
    $env:MSYS2_PATH_TYPE = 'inherit'

    $drive = (Get-Item (${PSScriptRoot})).PSDrive.Root
    $match = subst.exe | Select-String "${drive}\:"
    if ($match) {
        $scriptRoot = $PSScriptRoot -replace "${drive}\", ($match.ToString().Substring('C:\: => '.Length) + '\')
    } else {
        $scriptRoot = $PSScriptRoot
    }
    $scriptRoot = & $BashExe -c "wslpath -a $($scriptRoot -replace '\\','\\')"

    # Build ffmpeg - disable strict error handling since ffmpeg writes to error out
    $ErrorActionPreference = "Continue"
    & $BashExe --login -x $scriptRoot/FFmpegConfig.sh Win10 $Platform
    $ErrorActionPreference = "Stop"

    if ($lastexitcode -ne 0) { throw "Failed to build FFmpeg." }

    # Copy PDBs to built binaries dir
    Copy-Item $SolutionDir\ffmpeg\Output\Windows10\$Platform\*\*.pdb $SolutionDir\ffmpeg\Build\Windows10\$Platform\bin\
}

Write-Host
Write-Host "Building FFmpegInteropX..."
Write-Host

# Stop on all PowerShell command errors
$ErrorActionPreference = "Stop"

if (! (Test-Path $PSScriptRoot\ffmpeg\configure)) {
    Write-Error 'configure is not found in ffmpeg folder. Ensure this folder is populated with ffmpeg snapshot'
    Exit 1
}

if (!(Test-Path $BashExe)) {

    $msysFound = $false
    @( 'C:\msys64', 'C:\msys' ) | ForEach-Object {
        if (Test-Path $_) {
            $BashExe = "${_}\usr\bin\bash.exe"
            $msysFound = $true

            break
        }
    }

    # Search for MSYS locations
    if (! $msysFound) {
        Write-Error "MSYS2 not found."
        Exit 1;
    }
}

[System.IO.DirectoryInfo] $vsLatestPath = `
    & "$VSInstallerFolder\vswhere.exe" `
    $VsWhereCriteria `
    -property installationPath `
    -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64

Write-Host "Visual Studio Installation folder: [$vsLatestPath]"

# 14.16.27023 => v141
$platformToolSet = "v$($VcVersion.Major)$("$($VcVersion.Minor)"[0])"
Write-Host "Platform Toolset: [$platformToolSet]"

# Save orignal environment variables
$oldEnv = @{};
foreach ($item in Get-ChildItem env:)
{
    $oldEnv.Add($item.Name, $item.Value);
}

$start = Get-Date
$success = 1

foreach ($platform in $Platforms) {

    try
    {
        Build-Platform `
            -SolutionDir "${PSScriptRoot}\" `
            -Platform $platform `
            -Configuration 'Release' `
            -WindowsTargetPlatformVersion $WindowsTargetPlatformVersion `
            -VcVersion $VcVersion `
            -PlatformToolset $platformToolSet `
            -VsLatestPath $vsLatestPath `
            -BashExe $BashExe
    }
    catch
    {
        Write-Error "Error occured: $PSItem"
        $success = 0
        Break
    }
    finally
    {
        # Restore orignal environment variables
        foreach ($item in $oldEnv.GetEnumerator())
        {
            Set-Item -Path env:"$($item.Name)" -Value $item.Value
        }
        foreach ($item in Get-ChildItem env:)
        {
            if (!$oldEnv.ContainsKey($item.Name))
            {
                 Remove-Item -Path env:"$($item.Name)"
            }
        }
    }
}

Write-Host ''
Write-Host 'Time elapsed'
Write-Host ('{0}' -f ((Get-Date) - $start))
Write-Host ''

if ($success)
{
    Write-Host 'Build succeeded!'

}
else
{
    Write-Host 'Build failed!'
    Exit 1
}

