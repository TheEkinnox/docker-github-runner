#This script invokes GitHub-CLI (Already installed on container image)
#To use this entrypoint script run: Docker run -e GH_TOKEN='myPatToken' -e GH_OWNER='orgName' -e GH_REPOSITORY='repoName' -d imageName 
Param (
    [Parameter(Mandatory = $false)]
    [string]$owner = $env:GH_OWNER,
    [Parameter(Mandatory = $false)]
    [string]$repos = $env:GH_REPOSITORY,
    [Parameter(Mandatory = $false)]
    [string]$pat = $env:GH_TOKEN
)

try {
    # Setup profile
    if (![System.IO.File]::Exists($profile) -or ([System.IO.File]::ReadAllText($profile) -contains 'chocolateyProfile.psm1')) {
        Write-Host "Adding ChocolateyProfile to $profile"

        # Create the profile directory if it doesn't exist
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($profile))

        $ChocolateyProfile = @'
$ChocolateyProfile = "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
if (Test-Path($ChocolateyProfile)) {
    Import-Module "$ChocolateyProfile"
}
'@

        # Append the chocolatey profile to the ps profile
        [System.IO.File]::AppendAllText($profile, $ChocolateyProfile)
    }
}
catch {
    Write-Error $_.Exception.Message
}

#Use --with-token to pass in a PAT token on standard input. The minimum required scopes for the token are: "repo", "read:org".
#Alternatively, gh will use the authentication token found in environment variables. See gh help environment for more info.
#To use gh in GitHub Actions, add GH_TOKEN: $ to "env". on Docker run: Docker run -e GH_TOKEN='myPatToken'
gh auth login

$runnerBaseName = "dockerNode-"
$reposArray = ($repos -split ',')

foreach ($repo in $reposArray) {
    if ([System.IO.File]::Exists(".\\actions-runner.zip")) {
        Expand-Archive -Path ".\\actions-runner.zip" -DestinationPath ".\\runner-$repo"
    }

    #Get Runner registration Token
    $jsonObj = gh api --method POST -H "Accept: application/vnd.github.v3+json" "/repos/$owner/$repo/actions/runners/registration-token"
    $regToken = (ConvertFrom-Json -InputObject $jsonObj).token
    $runnerName = $runnerBaseName + (((New-Guid).Guid).replace("-", "")).substring(0, 5)
    $serviceName = "actions.runner.$owner-$repo.$runnerName"

    try {
        #Register new runner instance
        write-host "Registering GitHub Self Hosted Runner on: $owner/$repo"

        #Start runner listener for jobs
        if ($repo -eq $reposArray[-1]) {
            & "./runner-$repo/config.cmd" --unattended --url "https://github.com/$owner/$repo" --token $regToken --name $runnerName --replace
            & "./runner-$repo/run.cmd"
        }
        else {
            & "./runner-$repo/config.cmd" --unattended --url "https://github.com/$owner/$repo" --token $regToken --name $runnerName --replace --runasservice
        }
    }
    catch {
        Write-Error $_.Exception.Message

        if ($repo -ne $reposArray[-1]) {
            Stop-Service $serviceName
            Remove-Service $serviceName
        }
    }
    finally {
        # Trap signal with finally - cleanup (When docker container is stopped remove runner registration from GitHub)
        # Does not currently work due to issue: https://github.com/moby/moby/issues/25982#
        # Perform manual cleanup of stale runners using Cleanup-Runners.ps1
        # & "./runner-$repo/config.cmd" remove --unattended --token $regToken
    }
}

Remove-Item ".\\actions-runner.zip" -Force

#Remove PAT token after registering new instance
$pat = $null
$env:GH_TOKEN = $null
