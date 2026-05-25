param(
  [switch]$TestMode
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class NativeOverlay {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);
}
"@

$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rewardFile = Join-Path $baseDir "..\..\mods\RewardBridgeExport.current.json"
$aliasFile = Join-Path $baseDir "data\necrobinder_card_aliases.json"
$deckFile = Join-Path $baseDir "data\necrobinder_decks.json"
$runtimeStatusFile = Join-Path $baseDir "reward_overlay.runtime.json"
$runtimeLogFile = Join-Path $baseDir "reward_overlay.runtime.log"
$resolvedAppData = if ($env:APPDATA) { $env:APPDATA } else { [Environment]::GetFolderPath("ApplicationData") }
$appDataDir = if ($resolvedAppData) { Join-Path $resolvedAppData "SlayTheSpire2" } else { $null }

$script:AliasEntries = @()
$script:AliasById = @{}
$script:DeckEntries = @()
$script:DeckById = @{}
$script:SelectedDeckId = $null
$script:LastRenderHash = ""

function Write-RuntimeLog {
  param([string]$Message)

  try {
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}{2}" -f [DateTime]::Now, $Message, [Environment]::NewLine
    [System.IO.File]::AppendAllText($runtimeLogFile, $line, [System.Text.Encoding]::UTF8)
  } catch {
  }
}

function Write-RuntimeStatus {
  param(
    [string]$State,
    [string]$Message
  )

  try {
    $payload = [pscustomobject]@{
      timestamp = [DateTime]::UtcNow.ToString("o")
      pid = $PID
      state = $State
      message = $Message
    } | ConvertTo-Json -Depth 4

    [System.IO.File]::WriteAllText($runtimeStatusFile, $payload, [System.Text.UTF8Encoding]::new($false))
  } catch {
  }
}

function ConvertFrom-JsonFile {
  param([string]$Path)

  if (-not (Test-Path $Path)) {
    return $null
  }

  $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) {
    $raw = $raw.Substring(1)
  }

  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $null
  }

  return $raw | ConvertFrom-Json
}

function ConvertTo-ObjectArray {
  param($InputObject)

  $result = @()
  if ($null -eq $InputObject) {
    return $result
  }

  if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
    foreach ($item in $InputObject) {
      $result += $item
    }
    return $result
  }

  $result += $InputObject
  return $result
}

function Load-ReferenceData {
  Write-RuntimeLog "Loading reference data."
  $script:AliasEntries = ConvertTo-ObjectArray (ConvertFrom-JsonFile -Path $aliasFile)
  $script:AliasById = @{}
  foreach ($entry in $script:AliasEntries) {
    if ($null -ne $entry -and $null -ne $entry.id) {
      $script:AliasById[[string]$entry.id] = $entry
    }
  }

  $script:DeckEntries = ConvertTo-ObjectArray (ConvertFrom-JsonFile -Path $deckFile)
  $script:DeckById = @{}
  foreach ($deck in $script:DeckEntries) {
    if ($null -ne $deck -and $null -ne $deck.id) {
      $script:DeckById[[string]$deck.id] = $deck
    }
  }

  if (-not $script:SelectedDeckId -and $script:DeckEntries.Count -gt 0) {
    $script:SelectedDeckId = [string]$script:DeckEntries[0].id
  }
}

function Find-RunSavePath {
  if (-not $appDataDir -or -not (Test-Path $appDataDir)) {
    return $null
  }

  $allSaves = @(Get-ChildItem -Path $appDataDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^current_run(_mp)?\.save$' })

  if ($allSaves.Count -eq 0) {
    return $null
  }

  $singlePlayer = @($allSaves | Where-Object { $_.Name -ieq "current_run.save" } | Sort-Object LastWriteTime -Descending)
  if ($singlePlayer.Count -gt 0) {
    return $singlePlayer[0].FullName
  }

  return (@($allSaves | Sort-Object LastWriteTime -Descending))[0].FullName
}

function Get-CardLabel {
  param([string]$Id)

  if ([string]::IsNullOrWhiteSpace($Id)) {
    return [pscustomobject]@{
      Id = ""
      NameKo = ""
      NameEn = ""
      MatchStatus = "unknown"
    }
  }

  if ($script:AliasById.ContainsKey($Id)) {
    $entry = $script:AliasById[$Id]
    $nameKo = [string]$entry.name_ko
    $nameEn = [string]$entry.name_en
    if ([string]::IsNullOrWhiteSpace($nameKo)) {
      $nameKo = $nameEn
      $nameEn = ""
    }
    return [pscustomobject]@{
      Id = [string]$entry.id
      NameKo = $nameKo
      NameEn = $nameEn
      MatchStatus = [string]$entry.match_status
    }
  }

  return [pscustomobject]@{
    Id = $Id
    NameKo = $Id
    NameEn = $Id
    MatchStatus = "unknown"
  }
}

function Get-RunState {
  $savePath = Find-RunSavePath
  if (-not $savePath) {
    return [pscustomobject]@{
      SavePath = ""
      SaveName = ""
      CharacterId = ""
      Hp = ""
      Gold = ""
      DeckIds = @()
      RelicIds = @()
    }
  }

  try {
    $parsed = ConvertFrom-JsonFile -Path $savePath
    $player = @(ConvertTo-ObjectArray $parsed.players)[0]

    $deckIds = @()
    foreach ($card in (ConvertTo-ObjectArray $player.deck)) {
      if ($null -ne $card.id) {
        $deckIds += [string]$card.id
      }
    }

    $relicIds = @()
    foreach ($relic in (ConvertTo-ObjectArray $player.relics)) {
      if ($null -ne $relic.id) {
        $relicIds += [string]$relic.id
      }
    }

    return [pscustomobject]@{
      SavePath = $savePath
      SaveName = [System.IO.Path]::GetFileName($savePath)
      CharacterId = [string]$player.character_id
      Hp = $player.current_hp
      Gold = if ($null -ne $player.gold) { $player.gold } else { $player.current_gold }
      DeckIds = $deckIds
      RelicIds = $relicIds
    }
  } catch {
    return [pscustomobject]@{
      SavePath = $savePath
      SaveName = [System.IO.Path]::GetFileName($savePath)
      CharacterId = ""
      Hp = ""
      Gold = ""
      DeckIds = @()
      RelicIds = @()
      Error = $_.Exception.Message
    }
  }
}

function Get-RewardState {
  if (-not (Test-Path $rewardFile)) {
    return [pscustomobject]@{
      UpdatedAt = ""
      Reason = ""
      CardIds = @()
    }
  }

  try {
    $parsed = ConvertFrom-JsonFile -Path $rewardFile
    return [pscustomobject]@{
      UpdatedAt = [string]$parsed.updated_at
      Reason = [string]$parsed.reason
      CardIds = ConvertTo-ObjectArray $parsed.card_ids
    }
  } catch {
    return [pscustomobject]@{
      UpdatedAt = ""
      Reason = "invalid_json"
      CardIds = @()
      Error = $_.Exception.Message
    }
  }
}

function Get-DeckCardLookup {
  param($Deck)

  $lookup = @{}
  foreach ($id in (ConvertTo-ObjectArray $Deck.core)) {
    $lookup[[string]$id] = "core"
  }
  foreach ($id in (ConvertTo-ObjectArray $Deck.support)) {
    if (-not $lookup.ContainsKey([string]$id)) {
      $lookup[[string]$id] = "support"
    }
  }
  return $lookup
}

function Get-DeckCompletion {
  param(
    $Deck,
    [string[]]$CurrentDeckIds,
    [string]$PickedCardId
  )

  $currentSet = @{}
  foreach ($id in $CurrentDeckIds) {
    $currentSet[[string]$id] = $true
  }

  $afterSet = @{}
  foreach ($id in $CurrentDeckIds) {
    $afterSet[[string]$id] = $true
  }
  if ($PickedCardId) {
    $afterSet[[string]$PickedCardId] = $true
  }

  $total = 0
  $current = 0
  $after = 0

  foreach ($id in (ConvertTo-ObjectArray $Deck.core)) {
    $total += 2
    if ($currentSet.ContainsKey([string]$id)) { $current += 2 }
    if ($afterSet.ContainsKey([string]$id)) { $after += 2 }
  }

  foreach ($id in (ConvertTo-ObjectArray $Deck.support)) {
    $total += 1
    if ($currentSet.ContainsKey([string]$id)) { $current += 1 }
    if ($afterSet.ContainsKey([string]$id)) { $after += 1 }
  }

  if ($total -eq 0) {
    return [pscustomobject]@{
      CurrentPercent = 0
      AfterPercent = 0
      DeltaPercent = 0
    }
  }

  $currentPercent = [int][math]::Round(($current / $total) * 100)
  $afterPercent = [int][math]::Round(($after / $total) * 100)
  return [pscustomobject]@{
    CurrentPercent = $currentPercent
    AfterPercent = $afterPercent
    DeltaPercent = [int]($afterPercent - $currentPercent)
  }
}

function Get-CardDeckTags {
  param([string]$CardId)

  $tags = @()
  foreach ($deck in $script:DeckEntries) {
    $lookup = Get-DeckCardLookup -Deck $deck
    if ($lookup.ContainsKey([string]$CardId)) {
      $tags += [pscustomobject]@{
        DeckId = [string]$deck.id
        Label = [string]$deck.label
        Role = [string]$lookup[[string]$CardId]
        Color = [string]$deck.color
      }
    }
  }
  return $tags
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Reward Overlay"
        Width="1280"
        Height="720"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        Topmost="True"
        ShowInTaskbar="False"
        ResizeMode="NoResize"
        FontFamily="Malgun Gothic">
  <Grid Background="Transparent" Margin="16">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <DockPanel Grid.Row="0" Margin="0,0,0,10" LastChildFill="False">
        <StackPanel Orientation="Vertical" DockPanel.Dock="Left">
          <TextBlock Text="Reward Overlay" Foreground="#F8FAFC" FontSize="26" FontWeight="Bold"/>
          <TextBlock x:Name="RunSummaryText" Foreground="#CBD5E1" FontSize="13" />
        </StackPanel>
        <Button x:Name="CloseButton" DockPanel.Dock="Right" Content="X" Width="34" Height="34" Margin="8,0,0,0"
                Background="#CC7F1D1D" Foreground="White" FontSize="16" BorderThickness="0" Cursor="Hand"/>
      </DockPanel>

      <Border Grid.Row="1" Background="#8A111827" CornerRadius="10" Padding="12" Margin="0,0,0,14" HorizontalAlignment="Left">
        <StackPanel>
          <TextBlock x:Name="DeckSummaryText" Foreground="#E2E8F0" FontSize="15" FontWeight="SemiBold"/>
          <TextBlock x:Name="StateSummaryText" Foreground="#94A3B8" FontSize="12" Margin="0,4,0,0"/>
        </StackPanel>
      </Border>

      <UniformGrid Grid.Row="2" x:Name="CardGrid" Columns="3" Margin="80,40,80,14" VerticalAlignment="Top">
        <Border x:Name="Card1" Margin="10" Background="#8A111827" CornerRadius="14" BorderBrush="#667085" BorderThickness="1" Padding="14">
          <StackPanel>
            <WrapPanel x:Name="Card1Tags" Margin="0,0,0,8"/>
            <TextBlock x:Name="Card1NameKo" Foreground="#F8FAFC" FontSize="24" FontWeight="Bold" TextWrapping="Wrap"/>
            <TextBlock x:Name="Card1NameEn" Foreground="#93C5FD" FontSize="14" Margin="0,2,0,2"/>
            <TextBlock x:Name="Card1Id" Foreground="#64748B" FontSize="12" Margin="0,0,0,10"/>
            <Border Background="#AA052E16" CornerRadius="8" Padding="10" Margin="0,0,0,10">
              <StackPanel>
                <TextBlock x:Name="Card1DeckFit" Foreground="#86EFAC" FontSize="18" FontWeight="Bold"/>
                <TextBlock x:Name="Card1DeckDelta" Foreground="#BBF7D0" FontSize="12"/>
              </StackPanel>
            </Border>
            <TextBlock x:Name="Card1DeckRole" Foreground="#E2E8F0" FontSize="13" Margin="0,0,0,8"/>
            <TextBlock x:Name="Card1Hints" Foreground="#94A3B8" FontSize="12" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>
        <Border x:Name="Card2" Margin="10" Background="#8A111827" CornerRadius="14" BorderBrush="#667085" BorderThickness="1" Padding="14">
          <StackPanel>
            <WrapPanel x:Name="Card2Tags" Margin="0,0,0,8"/>
            <TextBlock x:Name="Card2NameKo" Foreground="#F8FAFC" FontSize="24" FontWeight="Bold" TextWrapping="Wrap"/>
            <TextBlock x:Name="Card2NameEn" Foreground="#93C5FD" FontSize="14" Margin="0,2,0,2"/>
            <TextBlock x:Name="Card2Id" Foreground="#64748B" FontSize="12" Margin="0,0,0,10"/>
            <Border Background="#AA052E16" CornerRadius="8" Padding="10" Margin="0,0,0,10">
              <StackPanel>
                <TextBlock x:Name="Card2DeckFit" Foreground="#86EFAC" FontSize="18" FontWeight="Bold"/>
                <TextBlock x:Name="Card2DeckDelta" Foreground="#BBF7D0" FontSize="12"/>
              </StackPanel>
            </Border>
            <TextBlock x:Name="Card2DeckRole" Foreground="#E2E8F0" FontSize="13" Margin="0,0,0,8"/>
            <TextBlock x:Name="Card2Hints" Foreground="#94A3B8" FontSize="12" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>
        <Border x:Name="Card3" Margin="10" Background="#8A111827" CornerRadius="14" BorderBrush="#667085" BorderThickness="1" Padding="14">
          <StackPanel>
            <WrapPanel x:Name="Card3Tags" Margin="0,0,0,8"/>
            <TextBlock x:Name="Card3NameKo" Foreground="#F8FAFC" FontSize="24" FontWeight="Bold" TextWrapping="Wrap"/>
            <TextBlock x:Name="Card3NameEn" Foreground="#93C5FD" FontSize="14" Margin="0,2,0,2"/>
            <TextBlock x:Name="Card3Id" Foreground="#64748B" FontSize="12" Margin="0,0,0,10"/>
            <Border Background="#AA052E16" CornerRadius="8" Padding="10" Margin="0,0,0,10">
              <StackPanel>
                <TextBlock x:Name="Card3DeckFit" Foreground="#86EFAC" FontSize="18" FontWeight="Bold"/>
                <TextBlock x:Name="Card3DeckDelta" Foreground="#BBF7D0" FontSize="12"/>
              </StackPanel>
            </Border>
            <TextBlock x:Name="Card3DeckRole" Foreground="#E2E8F0" FontSize="13" Margin="0,0,0,8"/>
            <TextBlock x:Name="Card3Hints" Foreground="#94A3B8" FontSize="12" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>
      </UniformGrid>

      <Border Grid.Row="3" Background="#B30B1220" CornerRadius="12" Padding="12" VerticalAlignment="Bottom">
        <StackPanel>
          <TextBlock Text="Available Decks" Foreground="#F8FAFC" FontSize="16" FontWeight="Bold" Margin="0,0,0,8"/>
          <WrapPanel x:Name="DeckButtonsPanel"/>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$window.WindowStartupLocation = "Manual"

$closeButton = $window.FindName("CloseButton")
$closeButton.Add_Click({ $window.Close() })

function Get-GameWindowHandle {
  try {
    $processes = @(Get-Process SlayTheSpire2 -ErrorAction SilentlyContinue | Sort-Object MainWindowHandle -Descending)
    if ($processes.Count -eq 0) {
      return [IntPtr]::Zero
    }

    foreach ($process in $processes) {
      if ($process.MainWindowHandle -and $process.MainWindowHandle -ne 0) {
        return [IntPtr]$process.MainWindowHandle
      }
    }

    $targetPid = [uint32]$processes[0].Id
    $script:FoundGameHandle = [IntPtr]::Zero
    $script:FoundGameArea = 0
    $callback = [NativeOverlay+EnumWindowsProc]{
      param([IntPtr]$hWnd, [IntPtr]$lParam)
      $pid = 0
      [void][NativeOverlay]::GetWindowThreadProcessId($hWnd, [ref]$pid)
      if ($pid -eq $targetPid -and [NativeOverlay]::IsWindowVisible($hWnd)) {
        $rect = New-Object NativeOverlay+RECT
        if ([NativeOverlay]::GetClientRect($hWnd, [ref]$rect)) {
          $width = [Math]::Max(0, $rect.Right - $rect.Left)
          $height = [Math]::Max(0, $rect.Bottom - $rect.Top)
          $area = $width * $height
          if ($area -gt $script:FoundGameArea) {
            $script:FoundGameHandle = $hWnd
            $script:FoundGameArea = $area
          }
        }
      }
      return $true
    }
    [void][NativeOverlay]::EnumWindows($callback, [IntPtr]::Zero)
    return $script:FoundGameHandle
  } catch {
    return [IntPtr]::Zero
  }
}

function Update-OverlayBounds {
  $handle = Get-GameWindowHandle
  if ($handle -eq [IntPtr]::Zero) {
    return
  }

  if ([NativeOverlay]::IsIconic($handle)) {
    if ($window.IsVisible) { $window.Hide() }
    return
  }

  $rect = New-Object NativeOverlay+RECT
  if (-not [NativeOverlay]::GetClientRect($handle, [ref]$rect)) {
    return
  }

  $topLeft = New-Object NativeOverlay+POINT
  $topLeft.X = $rect.Left
  $topLeft.Y = $rect.Top
  [void][NativeOverlay]::ClientToScreen($handle, [ref]$topLeft)

  $bottomRight = New-Object NativeOverlay+POINT
  $bottomRight.X = $rect.Right
  $bottomRight.Y = $rect.Bottom
  [void][NativeOverlay]::ClientToScreen($handle, [ref]$bottomRight)

  $width = [math]::Max(100, $bottomRight.X - $topLeft.X)
  $height = [math]::Max(100, $bottomRight.Y - $topLeft.Y)
  $window.Left = $topLeft.X
  $window.Top = $topLeft.Y
  $window.Width = $width
  $window.Height = $height
  if (-not $window.IsVisible) {
    $window.Show()
  }
}

function New-TagChip {
  param(
    [string]$Text,
    [string]$Color
  )

  $border = New-Object System.Windows.Controls.Border
  $border.CornerRadius = [System.Windows.CornerRadius]::new(10)
  $border.Margin = [System.Windows.Thickness]::new(0, 0, 6, 6)
  $border.Padding = [System.Windows.Thickness]::new(8, 3, 8, 3)
  $border.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)

  $tb = New-Object System.Windows.Controls.TextBlock
  $tb.Text = $Text
  $tb.Foreground = [System.Windows.Media.Brushes]::White
  $tb.FontSize = 11
  $tb.FontWeight = "SemiBold"
  $tb.FontFamily = [System.Windows.Media.FontFamily]::new("Malgun Gothic")

  $border.Child = $tb
  return $border
}

function Set-CardPanel {
  param(
    [int]$Index,
    $CardInfo,
    $DeckInfo
  )

  $panel = $window.FindName("Card$Index")
  $tagPanel = $window.FindName("Card${Index}Tags")
  $nameKo = $window.FindName("Card${Index}NameKo")
  $nameEn = $window.FindName("Card${Index}NameEn")
  $idText = $window.FindName("Card${Index}Id")
  $deckFit = $window.FindName("Card${Index}DeckFit")
  $deckDelta = $window.FindName("Card${Index}DeckDelta")
  $deckRole = $window.FindName("Card${Index}DeckRole")
  $hints = $window.FindName("Card${Index}Hints")

  $tagPanel.Children.Clear()

  if ($null -eq $CardInfo) {
    $panel.Visibility = "Hidden"
    return
  }

  $panel.Visibility = "Visible"
  $nameKo.Text = $CardInfo.Label.NameKo
  $nameEn.Text = $CardInfo.Label.NameEn
  $nameEn.Visibility = if ([string]::IsNullOrWhiteSpace($CardInfo.Label.NameEn)) { "Collapsed" } else { "Visible" }
  $idText.Text = $CardInfo.Label.Id
  $deckFit.Text = "$($DeckInfo.CurrentPercent)% -> $($DeckInfo.AfterPercent)%"

  $deltaPrefix = if ($DeckInfo.DeltaPercent -ge 0) { "+" } else { "" }
  $deckDelta.Text = "$($CardInfo.SelectedDeckLabel) progress $deltaPrefix$($DeckInfo.DeltaPercent)%"
  $deckRole.Text = $CardInfo.RoleText
  $hints.Text = $CardInfo.HintText

  foreach ($tag in $CardInfo.Tags) {
    $chipText = if ($tag.Role -eq "core") { "$($tag.Label) core" } else { "$($tag.Label) support" }
    $null = $tagPanel.Children.Add((New-TagChip -Text $chipText -Color $tag.Color))
  }

  if ($CardInfo.Tags.Count -eq 0) {
    $null = $tagPanel.Children.Add((New-TagChip -Text "No deck tags" -Color "#475569"))
  }
}

function Refresh-DeckButtons {
  param($RunState)

  $panel = $window.FindName("DeckButtonsPanel")
  $panel.Children.Clear()

  foreach ($deck in $script:DeckEntries) {
    $completion = Get-DeckCompletion -Deck $deck -CurrentDeckIds $RunState.DeckIds -PickedCardId $null

    $button = New-Object System.Windows.Controls.Button
    $button.Tag = [string]$deck.id
    $button.Margin = [System.Windows.Thickness]::new(0, 0, 8, 8)
    $button.Padding = [System.Windows.Thickness]::new(12, 8, 12, 8)
    $button.BorderThickness = [System.Windows.Thickness]::new(0)
    $button.Cursor = [System.Windows.Input.Cursors]::Hand

    if ([string]$deck.id -eq $script:SelectedDeckId) {
      $button.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString([string]$deck.color)
      $button.Foreground = [System.Windows.Media.Brushes]::White
    } else {
      $button.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#1E293B")
      $button.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#E2E8F0")
    }

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Orientation = "Vertical"

    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = [string]$deck.label
    $title.FontWeight = "Bold"
    $title.FontSize = 13
    $title.FontFamily = [System.Windows.Media.FontFamily]::new("Malgun Gothic")

    $sub = New-Object System.Windows.Controls.TextBlock
    $sub.Text = "$($completion.CurrentPercent)% - $([string]$deck.description)"
    $sub.FontSize = 11
    $sub.Opacity = 0.9
    $sub.FontFamily = [System.Windows.Media.FontFamily]::new("Malgun Gothic")

    $null = $stack.Children.Add($title)
    $null = $stack.Children.Add($sub)
    $button.Content = $stack

    $button.Add_Click({
      param($sender, $args)
      $script:SelectedDeckId = [string]$sender.Tag
      Refresh-Overlay
    })

    $null = $panel.Children.Add($button)
  }
}

function Refresh-Overlay {
  Write-RuntimeStatus -State "refreshing" -Message "Rendering overlay frame."
  Update-OverlayBounds

  $run = Get-RunState
  $reward = Get-RewardState
  $selectedDeck = if ($script:DeckById.ContainsKey($script:SelectedDeckId)) { $script:DeckById[$script:SelectedDeckId] } else { $null }

  $stateSignature = @{
    save = $run.SaveName
    hp = $run.Hp
    gold = $run.Gold
    deckCount = $run.DeckIds.Count
    relicCount = $run.RelicIds.Count
    cards = @($reward.CardIds)
    deck = $script:SelectedDeckId
  } | ConvertTo-Json -Compress

  if ($stateSignature -eq $script:LastRenderHash) {
    return
  }
  $script:LastRenderHash = $stateSignature

  $runSummaryText = $window.FindName("RunSummaryText")
  $deckSummaryText = $window.FindName("DeckSummaryText")
  $stateSummaryText = $window.FindName("StateSummaryText")

  $runSummaryText.Text = "Character: $($run.CharacterId)   HP: $($run.Hp)   GOLD: $($run.Gold)   SAVE: $($run.SaveName)"

  if ($null -eq $selectedDeck) {
    $deckSummaryText.Text = "No deck selected"
  } else {
    $overall = Get-DeckCompletion -Deck $selectedDeck -CurrentDeckIds $run.DeckIds -PickedCardId $null
    $deckSummaryText.Text = "$([string]$selectedDeck.label) deck - completion $($overall.CurrentPercent)%"
  }

  $stateSummaryText.Text = "Rewards $($reward.CardIds.Count) - Deck $($run.DeckIds.Count) - Relics $($run.RelicIds.Count) - Updated: $($reward.UpdatedAt)"

  Refresh-DeckButtons -RunState $run

  for ($i = 1; $i -le 3; $i++) {
    $cardId = if ($reward.CardIds.Count -ge $i) { [string]$reward.CardIds[$i - 1] } else { $null }
    if ([string]::IsNullOrWhiteSpace($cardId)) {
      Set-CardPanel -Index $i -CardInfo $null -DeckInfo $null
      continue
    }

    $label = Get-CardLabel -Id $cardId
    $tags = @(Get-CardDeckTags -CardId $cardId)
    $completion = if ($null -ne $selectedDeck) {
      Get-DeckCompletion -Deck $selectedDeck -CurrentDeckIds $run.DeckIds -PickedCardId $cardId
    } else {
      [pscustomobject]@{ CurrentPercent = 0; AfterPercent = 0; DeltaPercent = 0 }
    }

    $selectedLookup = if ($null -ne $selectedDeck) { Get-DeckCardLookup -Deck $selectedDeck } else { @{} }
    $selectedRole = if ($selectedLookup.ContainsKey($cardId)) { $selectedLookup[$cardId] } else { $null }
    $roleText = if ($selectedRole -eq "core") {
      "Core card for selected deck"
    } elseif ($selectedRole -eq "support") {
      "Support card for selected deck"
    } else {
      "No direct link to selected deck"
    }

    $hintText = if ($tags.Count -gt 0) {
      "Fits decks: " + (($tags | ForEach-Object { $_.Label }) -join ", ")
    } else {
      "No registered deck tags yet."
    }

    $cardInfo = [pscustomobject]@{
      Label = $label
      Tags = $tags
      RoleText = $roleText
      HintText = $hintText
      SelectedDeckLabel = if ($null -ne $selectedDeck) { [string]$selectedDeck.label } else { "Selected deck" }
    }

    Set-CardPanel -Index $i -CardInfo $cardInfo -DeckInfo $completion
  }

  Write-RuntimeStatus -State "running" -Message ("Cards={0}; Deck={1}; Save={2}" -f $reward.CardIds.Count, $script:SelectedDeckId, $run.SaveName)
}

try {
  Write-RuntimeStatus -State "starting" -Message "Overlay script starting."
  Load-ReferenceData

  if ($TestMode) {
    $run = Get-RunState
    $reward = Get-RewardState
    [pscustomobject]@{
      SaveName = $run.SaveName
      Character = $run.CharacterId
      Hp = $run.Hp
      Gold = $run.Gold
      DeckCount = $run.DeckIds.Count
      RelicCount = $run.RelicIds.Count
      RewardCards = @($reward.CardIds)
      Decks = @($script:DeckEntries | ForEach-Object { $_.label })
    } | ConvertTo-Json -Depth 5
    Write-RuntimeStatus -State "test" -Message "Test mode completed."
    return
  }

  $timer = New-Object System.Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromMilliseconds(250)
  $timer.Add_Tick({
    try {
      Refresh-Overlay
    } catch {
      Write-RuntimeLog ("Refresh failure: " + $_.Exception.ToString())
      Write-RuntimeStatus -State "error" -Message $_.Exception.Message
    }
  })
  $timer.Start()

  Refresh-Overlay
  Write-RuntimeStatus -State "visible" -Message "Overlay window opened."
  $app = New-Object System.Windows.Application
  [void]$app.Run($window)
  Write-RuntimeStatus -State "closed" -Message "Overlay window closed."
} catch {
  Write-RuntimeLog ("Fatal failure: " + $_.Exception.ToString())
  Write-RuntimeStatus -State "error" -Message $_.Exception.Message
  throw
}
