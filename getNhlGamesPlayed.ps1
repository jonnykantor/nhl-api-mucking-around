<#
    .SYNOPSIS
        Return game status counts and opponent info for each NHL team that meets the various configured requirements of the call        
    .DESCRIPTION
        This program makes 2 calls out to the NHL's API against the teams and schedule endpoints. It then processes the returned
        data to present a table with at most one row per team showing the number of games by game status in the configured date
        range, as well as which opponents the team is playing in that date range
    .EXAMPLE
        .\Get-NHL-Schedule.ps1 -BeginDate 2021-10-17 -EndDate 2021-10-24 -Teams @("Vancouver Canucks", "Seattle Kraken") -MinGames 2 -MaxGames 4 -GameStateFilter "Scheduled"       
        Should return at most one row per team for Vancouver and Seattle but only if they have 2, 3, or 4 games between October 17th and October 24th (inclusive) that have
        a game status of 'Scheduled' (that is, it is still scheduled to be played)
    .OUTPUTS
        A formatted table with columns: Team, Total, Scheduled, Postponed, Final, Playing Against. 
        Team lists the name of the team
        Playing Against is an array of team names that Team is playing against in the date range
        Total is the total games independent of status
        Scheduled is games that are still scheduled to occur
        Postponed are games that have been postponed
        Final are games that have already been played
#>

# TODO:
#   - [ ] Better response validation, don't just throw on non-200's
#   - [ ] Implement partial name searching for teams (probably hard)
#   - [ ] Better documentation
#   - [ ] Parameterize game statuses?

param (
    [string]
    # Show only games on or after this date. Example: 2021-10-31
    $BeginDate = (Get-Date -f yyyy-MM-dd),

    [string]
    # Show only games on or before this date. Example: 2021-11-07
    $EndDate = (Get-Date -f yyyy-MM-dd),
    
    [string[]]
    # Only return results for the teams in this array. If left blank, all teams will be considered
    $Teams,

    [ValidateRange(0, 82)]
    [int]
    # Only return results for a team if they have at least this many games in the specified 'GameStateFilter' status
    $MinGames = 0,

    [ValidateRange(1, 82)]
    [int]
    # Only return results for a team if that have at most this many games in the specified 'GameStateFilter' status
    $MaxGames = 82,

    [string]
    # Determines which games from the valid statuses ('Total', 'Scheduled', 'Postponed', 'Final') will be considered
    # when filtering for MinGames and MaxGames
    $GameStateFilter = "Total"
)

$statsApiBase = "https://statsapi.web.nhl.com/api/v1/"
$teamsApi = "$($statsApiBase)teams/"
$scheduleApi = "$($statsApiBase)schedule?"

function Select-TeamGames {    
    Assert-GoodDateRange
    Assert-GoodGameRange
    
    $ScheduleObj = (Get-Schedule).Content | ConvertFrom-Json
    $TeamsDict = @{}
    
    $ScheduleObj.dates.games | ForEach-Object -Process {
        $Status = $_.status
        $_.teams | ForEach-Object -Process {
            Add-ToTeamsDictionary -TeamName $_.away.team.name -Status $Status.detailedState -Dictionary $TeamsDict -PlayingAgainstTeamName $_.home.team.name;
            Add-ToTeamsDictionary -TeamName $_.home.team.name -Status $Status.detailedState -Dictionary $TeamsDict -PlayingAgainstTeamName $_.away.team.name;
        }
    }

    $TeamsDict = Remove-InvalidGamesPlayedTeams -TeamsDict $TeamsDict

    return $TeamsDict | Format-ResultData
}

function Format-ResultData {
    param(
        [Parameter(Mandatory, ValueFromPipeline)]                
        [HashTable]$TeamsDict
    )

    # TODO: Parameterize the format?
    return $TeamsDict.Values | ForEach-Object {new-object psobject -Property $_} | Sort-Object -Property Team | Format-Table @("Team", "Total", "Scheduled", "Postponed", "Final", "Playing Against")
}

function Remove-InvalidGamesPlayedTeams {
    param(
        [Hashtable]$TeamsDict
    )

    $TeamsDict = Remove-TeamsBelowGamesPlayedMin -TeamsDict $TeamsDict
    $TeamsDict = Remove-TeamsAboveGamesPlayedMax -TeamsDict $TeamsDict
    return $TeamsDict
}

function Remove-TeamsBelowGamesPlayedMin {
    param(
        [Hashtable]$TeamsDict
    )
    
    # MinGames checks for 0 now, as it could be filtering against a status that has 0 such games (e.g. if 'Final' is chosen)
    # when no games have been played in the date range yet
    if ($MinGames -eq 0){
        return $TeamsDict
    }

    $AdjustedDict = @{}
    $TeamsDict.Keys | ForEach-Object -Process {
        if (($TeamsDict[$_][$GameStateFilter] -gt $MinGames) -or ($TeamsDict[$_][$GameStateFilter] -eq $MinGames)){
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
        if (($TeamsDict[$_][$GameStateFilter] -lt $MaxGames) -or ($TeamsDict[$_][$GameStateFilter] -eq $MaxGames)){
            $AdjustedDict[$_] = $TeamsDict[$_]
        }
    }

    return $AdjustedDict
}

function Add-ToTeamsDictionary{
    param(        
        [string]$TeamName,     
        [string]$Status,   
        [Hashtable]$Dictionary,
        [string]$PlayingAgainstTeamName
    )

    if (($Teams.Count -eq 0) -or ($Teams.Contains($TeamName))){
        $GamesByStatusForTeam = $Dictionary[$TeamName]

        if ($null -eq $GamesByStatusForTeam){
            $GamesByStatusForTeam = @{"Team"=$TeamName; "Final"=0; "Scheduled"=0; "Postponed"=0; "Playing Against"=[System.Collections.ArrayList]@()}
        }


        $SwallowIndex = $GamesByStatusForTeam["Playing Against"].Add($PlayingAgainstTeamName)
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