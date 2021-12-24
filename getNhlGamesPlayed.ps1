<#
    .SYNOPSIS
        A script that will return the number of games played by team in a specified
        date range, potentially filtering out teams that did not meet a minimum
        threshold for games played
    .DESCRIPTION
        This script takes in 2 dates, a BeginDate, and an EndDate. 
        If EndDate is not provided, it will default to the current date
        If BeginDate is not provided, it will default to the current date
        If an invalid date range is provided the program will swear at you

        It then calls the various NHL API endpoints to determine the schedule for
        all teams, and returns the number of games they will play in the specified
        date range, inclusive of the 2 dates provided
    .EXAMPLE
        .\Get-NHL-Schedule.ps1 -BeginDate 2021-10-17 -EndDate 2021-10-24 -Teams @("Vancouver Canucks", "Seattle Kraken") -MinGames 2       
        Should return the team + number of games played by Vancouver and Seattle from October 17, 2021 through October 24, 2021, 
        but only if they played 2 or more games
    .OUTPUTS
        A list of Team_Name: Games_Played    
#>

# TODO:
#   - [ ] Better response validation, don't just throw on non-200's
#   - [ ] Implement partial name searching for teams (probably hard)
#   - [ ] Better documentation

param (
    [string]$BeginDate = (Get-Date -f yyyy-MM-dd),    
    [string]$EndDate = (Get-Date -f yyyy-MM-dd),    
    [string[]]$Teams,
    [ValidateRange(1, 82)]
    [int]$MinGames = 1,
    [ValidateRange(1, 82)]
    [int]$MaxGames = 82
)

$statsApiBase = "https://statsapi.web.nhl.com/api/v1/"
$teamsApi = "$($statsApiBase)teams/"
$scheduleApi = "$($statsApiBase)schedule?"

function Select-TeamGames {
    # Validation
    Assert-GoodDateRange
    Assert-GoodGameRange
    
    $ScheduleObj = (Get-Schedule).Content | ConvertFrom-Json

    # Object looks like:
    # dates
    #   games
    #       teams
    #           away | home
    #               team
    #                   name

    $TeamsDict = @{}
    
    $ScheduleObj.dates.games | ForEach-Object -Process {
        $Status = $_.status
        $_.teams | ForEach-Object -Process {
            Add-ToTeamsDictionary -TeamName $_.away.team.name -Status $Status.detailedState -Dictionary $TeamsDict;
            Add-ToTeamsDictionary -TeamName $_.home.team.name -Status $Status.detailedState -Dictionary $TeamsDict;                
        }
    }

    #$ScheduleObj.dates.games.teams | ForEach-Object -Process {
    #    Add-ToTeamsDictionary -TeamName $_.away.team.name -Dictionary $TeamsDict;
    #    Add-ToTeamsDictionary -TeamName $_.home.team.name -Dictionary $TeamsDict;
    #}

    $TeamsDict = Remove-InvalidGamesPlayedTeams -TeamsDict $TeamsDict

    return $TeamsDict
}

function Remove-InvalidGamesPlayedTeams {
    param(
        [Hashtable]$TeamsDict
    )
    
    # TODO: Validate good games played range

    $TeamsDict = Remove-TeamsBelowGamesPlayedMin -TeamsDict $TeamsDict
    $TeamsDict = Remove-TeamsAboveGamesPlayedMax -TeamsDict $TeamsDict
    return $TeamsDict
}

function Remove-TeamsBelowGamesPlayedMin {
    param(
        [Hashtable]$TeamsDict
    )
    
    # Schedule doesn't list teams that don't play games, so 1 is the minimum
    if ($MinGames -eq 1){
        return $TeamsDict
    }

    $AdjustedDict = @{}
    $TeamsDict.Keys | ForEach-Object -Process {
        if (($TeamsDict[$_]['Total'] -gt $MinGames) -or ($TeamsDict[$_]['Total'] -eq $MinGames)){
            $AdjustedDict[$_] = $TeamsDict[$_]
        }
    }

    return $AdjustedDict
}

function Remove-TeamsAboveGamesPlayedMax {
    param(
        [Hashtable]$TeamsDict
    )

    if ($MaxGames -eq 82){
        return $TeamsDict
    }

    $AdjustedDict = @{}
    $TeamsDict.Keys | ForEach-Object -Process {
        if (($TeamsDict[$_]['Total'] -lt $MaxGames) -or ($TeamsDict[$_]['Total'] -eq $MaxGames)){
            $AdjustedDict[$_] = $TeamsDict[$_]
        }
    }

    return $AdjustedDict
}

function Add-ToTeamsDictionary{
    param(        
        [string]$TeamName,     
        [string]$Status,   
        [Hashtable]$Dictionary
    )

    if (($Teams.Count -eq 0) -or ($Teams.Contains($TeamName))){
        $GamesByStatusForTeam = $Dictionary[$TeamName]

        if ($null -eq $GamesByStatusForTeam){
            $GamesByStatusForTeam = @{"Team"=$TeamName}
        }

        $GamesByStatusForTeam[$Status]++

        $GamesByStatusForTeam['Total']++

        $Dictionary[$TeamName] = $GamesByStatusForTeam
    }
}

function Get-Schedule {    
    $RequestUrl = "$($scheduleApi)"    

    if ($BeginDate -eq $EndDate){
        $RequestUrl = "$($RequestUrl)&date=$($BeginDate)"
    }
    else {
        $RequestUrl = "$($RequestUrl)&startDate=$($BeginDate)&endDate=$($EndDate)"
    }
    
    $TeamQs = "teamId=$((Get-TeamIds).id -join ",")"
    $RequestUrl = "$($RequestUrl)&$($TeamQs)"

    $ScheduleResponse = Invoke-WebRequest $RequestUrl

    Assert-GoodResponse -Url $RequestUrl -Response $ScheduleResponse

    return $ScheduleResponse
}

function Get-TeamIds {    
    $TeamsResponse = Invoke-WebRequest $teamsApi
    
    Assert-GoodResponse -Url $teamsApi -Response $TeamsResponse    
    
    $AllTeamsObj = $TeamsResponse.Content | ConvertFrom-Json

    # filter down by team name if param was provided    
    if ($Teams.Count -gt 0){
        $FilteredTeams = $AllTeamsObj.Teams | Where-Object -Property name -in $Teams
        $TeamIds = $FilteredTeams | Select-Object -Property id
        if ($TeamIds.Count -eq 0){
            return "No team IDs retrievable from input team names: '$($Teams)'. Make sure you have the team name structured like 'Location TeamName'. E.g. '@(""Vancouver Canucks"", ""Seattle Kraken"")'"
        }
        return $TeamIds
    }

    $TeamIds = $AllTeamsObj.Teams | Select-Object -Property id
    return $TeamIds
}

function Assert-GoodResponse {
    param(        
        [string]$Url,        
        [Microsoft.PowerShell.Commands.WebResponseObject]$Response
    )

    # TODO: More validtion and handling of non-200 responses
    if ($Response.StatusCode -ne 200){
        throw "The request made to $($url) failed with status code: $($Response.StatusCode) and description: $($Response.StatusDescription)"
    }
}

function Assert-GoodDateRange {
    # Validation of dates needs to occur here, because ValidateScript can only 
    # operate on individual parameters
    if ((Get-Date $EndDate) -lt (Get-Date $BeginDate)){
        throw "The Specified EndDate: '$($EndDate)' occurs before the specified BeginDate: '$($BeginDate)'. Note that if BeginDate is not provided, it will default to the current date"
    }
}

function Assert-GoodGameRange {
    if ($MinGames -gt $MaxGames) {
        throw "The provided '-MinGames' setting: '$($MinGames)' is greater than the provided '-MaxGames' setting: '$($MaxGames)'. This is not valid."
    }
}

Select-TeamGames