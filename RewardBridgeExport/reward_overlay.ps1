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
$rewardFile = Join-Path $baseDir "..\mods\RewardBridgeExport.current.json"
$combatFile = Join-Path $baseDir "..\mods\RewardBridgeExport.combat.json"
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
$script:OverlayActiveReasons = @(
  "screen_ready",
  "screen_ready_scan",
  "button_ready",
  "hook_arg",
  "hook_before_capture",
  "merchant_screen_ready",
  "merchant_card_ready",
  "choose_card_screen_ready",
  "simple_card_screen_ready",
  "grid_card_screen_ready"
)

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
      IsActive = $false
    }
  }

  try {
    $parsed = ConvertFrom-JsonFile -Path $rewardFile
    $cardIds = ConvertTo-ObjectArray $parsed.card_ids
    $reason = [string]$parsed.reason
    return [pscustomobject]@{
      UpdatedAt = [string]$parsed.updated_at
      Reason = $reason
      CardIds = $cardIds
      IsActive = ($cardIds.Count -gt 0 -or $script:OverlayActiveReasons -contains $reason)
    }
  } catch {
    return [pscustomobject]@{
      UpdatedAt = ""
      Reason = "invalid_json"
      CardIds = @()
      IsActive = $false
      Error = $_.Exception.Message
    }
  }
}

function Get-CombatState {
  if (-not (Test-Path $combatFile)) {
    return [pscustomobject]@{
      Active = $false
      Turn = 0
      Players = @()
      Reason = ""
      UpdatedAt = ""
    }
  }

  try {
    $parsed = ConvertFrom-JsonFile -Path $combatFile
    return [pscustomobject]@{
      Active = [bool]$parsed.active
      Turn = if ($null -ne $parsed.turn) { [int]$parsed.turn } else { 0 }
      Players = ConvertTo-ObjectArray $parsed.players
      Reason = [string]$parsed.reason
      UpdatedAt = [string]$parsed.updated_at
    }
  } catch {
    return [pscustomobject]@{
      Active = $false
      Turn = 0
      Players = @()
      Reason = "invalid_json"
      UpdatedAt = ""
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

      <DockPanel Grid.Row="0" Margin="0,0,0,4" LastChildFill="False">
        <StackPanel Orientation="Vertical" DockPanel.Dock="Left">
          <TextBlock Text="Reward Overlay" Foreground="#F8FAFC" FontSize="16" FontWeight="Bold"/>
          <TextBlock x:Name="RunSummaryText" Foreground="#CBD5E1" FontSize="10" />
        </StackPanel>
        <Button x:Name="CloseButton" DockPanel.Dock="Right" Content="X" Width="28" Height="28" Margin="8,0,0,0"
                Background="#CC7F1D1D" Foreground="White" FontSize="14" BorderThickness="0" Cursor="Hand"/>
      </DockPanel>

      <Border Grid.Row="1" Background="#8A111827" CornerRadius="8" Padding="7" Margin="0,0,0,8" HorizontalAlignment="Left">
        <StackPanel>
          <TextBlock x:Name="DeckSummaryText" Foreground="#E2E8F0" FontSize="11" FontWeight="SemiBold"/>
          <TextBlock x:Name="StateSummaryText" Foreground="#94A3B8" FontSize="10" Margin="0,2,0,0" Visibility="Collapsed"/>
        </StackPanel>
      </Border>

      <Border Grid.Row="2" x:Name="CombatPanel" Background="#D908101B" CornerRadius="2" Padding="0"
              HorizontalAlignment="Right" VerticalAlignment="Top" Width="360" Margin="0,16,18,0"
              BorderBrush="#F70A6C" BorderThickness="1" Visibility="Collapsed">
        <StackPanel>
          <Grid Background="#F70A6C" Height="24">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="CombatTitle" Grid.Column="0" Foreground="White" FontSize="12" FontWeight="Bold"
                       VerticalAlignment="Center" Margin="8,0,0,0"/>
            <TextBlock x:Name="CombatSubTitle" Grid.Column="1" Foreground="#FFE4F0" FontSize="10"
                       VerticalAlignment="Center" Margin="0,0,8,0"/>
          </Grid>
          <StackPanel x:Name="CombatBodyPanel">
            <Border Background="#111827" BorderBrush="#F70A6C" BorderThickness="0,1,0,1" Padding="6,4">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="2*"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="PLAYER DAMAGE" Foreground="#F9A8D4" FontSize="10" FontWeight="Bold"/>
                <TextBlock Grid.Column="1" Text="TOTAL" Foreground="#CBD5E1" FontSize="10" FontWeight="Bold" TextAlignment="Right"/>
                <TextBlock Grid.Column="2" Text="TURN" Foreground="#CBD5E1" FontSize="10" FontWeight="Bold" TextAlignment="Right"/>
                <TextBlock Grid.Column="3" Text="SPECIAL" Foreground="#CBD5E1" FontSize="10" FontWeight="Bold" TextAlignment="Right"/>
                <TextBlock Grid.Column="4" Text="" Foreground="#CBD5E1" FontSize="10" FontWeight="Bold" TextAlignment="Right"/>
              </Grid>
            </Border>
            <StackPanel x:Name="CombatPlayerList"/>
          </StackPanel>
        </StackPanel>
      </Border>

      <Grid Grid.Row="2" x:Name="CardGrid" Width="980" Height="610" Margin="0,246,0,14" HorizontalAlignment="Center" VerticalAlignment="Top">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Canvas Grid.Column="0" Height="610">
          <Border x:Name="Card1" Canvas.Top="0" Width="248" Height="60" Canvas.Left="39" Background="#B30B1220" CornerRadius="8" BorderBrush="#667085" BorderThickness="1" Padding="6">
            <StackPanel>
              <WrapPanel x:Name="Card1Tags" Margin="0,0,0,3"/>
              <TextBlock x:Name="Card1NameKo" Foreground="#F8FAFC" FontSize="15" FontWeight="Bold" TextWrapping="Wrap"/>
              <TextBlock x:Name="Card1NameEn" Foreground="#93C5FD" FontSize="10" Margin="0,0,0,0"/>
              <TextBlock x:Name="Card1Id" Foreground="#64748B" FontSize="10" Margin="0,0,0,0" Visibility="Collapsed"/>
              <TextBlock x:Name="Card1DeckRole" Foreground="#E2E8F0" FontSize="10" Visibility="Collapsed"/>
              <TextBlock x:Name="Card1Hints" Foreground="#94A3B8" FontSize="10" TextWrapping="Wrap" Visibility="Collapsed"/>
            </StackPanel>
          </Border>
          <Border x:Name="Card1Progress" Canvas.Top="430" Width="248" Height="60" Canvas.Left="39" Background="#B3052E16" CornerRadius="8" BorderBrush="#14532D" BorderThickness="1" Padding="9">
            <StackPanel>
              <TextBlock x:Name="Card1DeckFit" Foreground="#86EFAC" FontSize="15" FontWeight="Bold"/>
              <TextBlock x:Name="Card1DeckDelta" Foreground="#BBF7D0" FontSize="11" Margin="0,2,0,0"/>
            </StackPanel>
          </Border>
        </Canvas>
        <Canvas Grid.Column="1" Height="610">
          <Border x:Name="Card2" Canvas.Top="0" Width="248" Height="60" Canvas.Left="39" Background="#B30B1220" CornerRadius="8" BorderBrush="#667085" BorderThickness="1" Padding="6">
            <StackPanel>
              <WrapPanel x:Name="Card2Tags" Margin="0,0,0,3"/>
              <TextBlock x:Name="Card2NameKo" Foreground="#F8FAFC" FontSize="15" FontWeight="Bold" TextWrapping="Wrap"/>
              <TextBlock x:Name="Card2NameEn" Foreground="#93C5FD" FontSize="10" Margin="0,0,0,0"/>
              <TextBlock x:Name="Card2Id" Foreground="#64748B" FontSize="10" Margin="0,0,0,0" Visibility="Collapsed"/>
              <TextBlock x:Name="Card2DeckRole" Foreground="#E2E8F0" FontSize="10" Visibility="Collapsed"/>
              <TextBlock x:Name="Card2Hints" Foreground="#94A3B8" FontSize="10" TextWrapping="Wrap" Visibility="Collapsed"/>
            </StackPanel>
          </Border>
          <Border x:Name="Card2Progress" Canvas.Top="430" Width="248" Height="60" Canvas.Left="39" Background="#B3052E16" CornerRadius="8" BorderBrush="#14532D" BorderThickness="1" Padding="9">
            <StackPanel>
              <TextBlock x:Name="Card2DeckFit" Foreground="#86EFAC" FontSize="15" FontWeight="Bold"/>
              <TextBlock x:Name="Card2DeckDelta" Foreground="#BBF7D0" FontSize="11" Margin="0,2,0,0"/>
            </StackPanel>
          </Border>
        </Canvas>
        <Canvas Grid.Column="2" Height="610">
          <Border x:Name="Card3" Canvas.Top="0" Width="248" Height="60" Canvas.Left="39" Background="#B30B1220" CornerRadius="8" BorderBrush="#667085" BorderThickness="1" Padding="6">
            <StackPanel>
              <WrapPanel x:Name="Card3Tags" Margin="0,0,0,3"/>
              <TextBlock x:Name="Card3NameKo" Foreground="#F8FAFC" FontSize="15" FontWeight="Bold" TextWrapping="Wrap"/>
              <TextBlock x:Name="Card3NameEn" Foreground="#93C5FD" FontSize="10" Margin="0,0,0,0"/>
              <TextBlock x:Name="Card3Id" Foreground="#64748B" FontSize="10" Margin="0,0,0,0" Visibility="Collapsed"/>
              <TextBlock x:Name="Card3DeckRole" Foreground="#E2E8F0" FontSize="10" Visibility="Collapsed"/>
              <TextBlock x:Name="Card3Hints" Foreground="#94A3B8" FontSize="10" TextWrapping="Wrap" Visibility="Collapsed"/>
            </StackPanel>
          </Border>
          <Border x:Name="Card3Progress" Canvas.Top="430" Width="248" Height="60" Canvas.Left="39" Background="#B3052E16" CornerRadius="8" BorderBrush="#14532D" BorderThickness="1" Padding="9">
            <StackPanel>
              <TextBlock x:Name="Card3DeckFit" Foreground="#86EFAC" FontSize="15" FontWeight="Bold"/>
              <TextBlock x:Name="Card3DeckDelta" Foreground="#BBF7D0" FontSize="11" Margin="0,2,0,0"/>
            </StackPanel>
          </Border>
        </Canvas>
      </Grid>

      <Border Grid.Row="2" x:Name="TargetDeckPanel" Width="230" MaxHeight="430" Margin="0,118,0,0"
              HorizontalAlignment="Left" VerticalAlignment="Top" Background="#B30B1220"
              CornerRadius="8" BorderBrush="#334155" BorderThickness="1" Padding="9">
        <StackPanel>
          <TextBlock x:Name="TargetDeckTitle" Foreground="#F8FAFC" FontSize="13" FontWeight="Bold" Margin="0,0,0,5"/>
          <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" MaxHeight="384">
            <StackPanel x:Name="TargetDeckList"/>
          </ScrollViewer>
        </StackPanel>
      </Border>

      <Border Grid.Row="3" x:Name="DeckSelectorPanel" Background="#B30B1220" CornerRadius="8" Padding="8" VerticalAlignment="Bottom">
        <DockPanel LastChildFill="True">
          <TextBlock Text="덱" Foreground="#CBD5E1" FontSize="12" FontWeight="Bold" Margin="0,0,8,0"
                     VerticalAlignment="Center" DockPanel.Dock="Left"/>
          <ScrollViewer HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Disabled"
                        CanContentScroll="True" Height="62">
            <StackPanel x:Name="DeckButtonsPanel" Orientation="Horizontal" VerticalAlignment="Center"/>
          </ScrollViewer>
        </DockPanel>
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
    $window.Left = 0
    $window.Top = 0
    $window.Width = [System.Windows.SystemParameters]::PrimaryScreenWidth
    $window.Height = [System.Windows.SystemParameters]::PrimaryScreenHeight
    if (-not $window.IsVisible) {
      $window.Show()
    }
    $window.Topmost = $false
    $window.Topmost = $true
    return $false
  }

  if ([NativeOverlay]::IsIconic($handle)) {
    if ($window.IsVisible) { $window.Hide() }
    return $false
  }

  $rect = New-Object NativeOverlay+RECT
  if (-not [NativeOverlay]::GetClientRect($handle, [ref]$rect)) {
    return $false
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
  $window.Topmost = $false
  $window.Topmost = $true
  return $true
}

function New-TagChip {
  param(
    [string]$Text,
    [string]$Color
  )

  $border = New-Object System.Windows.Controls.Border
  $border.CornerRadius = [System.Windows.CornerRadius]::new(8)
  $border.Margin = [System.Windows.Thickness]::new(0, 0, 4, 3)
  $border.Padding = [System.Windows.Thickness]::new(6, 2, 6, 2)
  $border.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)

  $tb = New-Object System.Windows.Controls.TextBlock
  $tb.Text = $Text
  $tb.Foreground = [System.Windows.Media.Brushes]::White
  $tb.FontSize = 10
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
  $progressPanel = $window.FindName("Card${Index}Progress")
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
    if ($null -ne $progressPanel) { $progressPanel.Visibility = "Hidden" }
    return
  }

  $panel.Visibility = "Visible"
  if ($null -ne $progressPanel) { $progressPanel.Visibility = "Visible" }
  if ($CardInfo.IsBestPick) {
    $panel.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FACC15")
    $panel.BorderThickness = [System.Windows.Thickness]::new(3)
    if ($null -ne $progressPanel) {
      $progressPanel.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FACC15")
      $progressPanel.BorderThickness = [System.Windows.Thickness]::new(2)
    }
  } elseif ($DeckInfo.DeltaPercent -gt 0) {
    $panel.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#22C55E")
    $panel.BorderThickness = [System.Windows.Thickness]::new(2)
    if ($null -ne $progressPanel) {
      $progressPanel.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#22C55E")
      $progressPanel.BorderThickness = [System.Windows.Thickness]::new(1)
    }
  } else {
    $panel.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#667085")
    $panel.BorderThickness = [System.Windows.Thickness]::new(1)
    if ($null -ne $progressPanel) {
      $progressPanel.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#14532D")
      $progressPanel.BorderThickness = [System.Windows.Thickness]::new(1)
    }
  }

  $nameKo.Text = $CardInfo.Label.NameKo
  $nameEn.Text = $CardInfo.Label.NameEn
  $nameEn.Visibility = if ([string]::IsNullOrWhiteSpace($CardInfo.Label.NameEn)) { "Collapsed" } else { "Visible" }
  $idText.Text = $CardInfo.Label.Id
  $deckFit.Text = "$($DeckInfo.CurrentPercent)% -> $($DeckInfo.AfterPercent)%"

  $deltaPrefix = if ($DeckInfo.DeltaPercent -ge 0) { "+" } else { "" }
  $deckDelta.Text = "완성도 $deltaPrefix$($DeckInfo.DeltaPercent)%"
  $deckRole.Text = $CardInfo.RoleText
  $hints.Text = $CardInfo.HintText

  if ($CardInfo.Rank -gt 0) {
    $rankColor = if ($CardInfo.IsBestPick) { "#D97706" } elseif ($DeckInfo.DeltaPercent -gt 0) { "#16A34A" } else { "#475569" }
    $rankText = if ($CardInfo.IsBestPick) { "추천 #1" } else { "추천 #$($CardInfo.Rank)" }
    $null = $tagPanel.Children.Add((New-TagChip -Text $rankText -Color $rankColor))
  }

  $addedTagCount = 0
  foreach ($tag in $CardInfo.Tags) {
    if ($addedTagCount -ge 3) {
      break
    }

    $roleText = if ($tag.Role -eq "core") { "핵심" } else { "보조" }
    $chipText = "$($tag.Label) $roleText"
    $null = $tagPanel.Children.Add((New-TagChip -Text $chipText -Color $tag.Color))
    $addedTagCount += 1
  }

  if ($addedTagCount -eq 0) {
    $null = $tagPanel.Children.Add((New-TagChip -Text "무관" -Color "#475569"))
  }
}

function Refresh-DeckButtons {
  param($RunState)

  $panel = $window.FindName("DeckButtonsPanel")
  $panel.Children.Clear()

  $deckRows = @()
  foreach ($deck in $script:DeckEntries) {
    $completion = Get-DeckCompletion -Deck $deck -CurrentDeckIds $RunState.DeckIds -PickedCardId $null
    $deckRows += [pscustomobject]@{
      Deck = $deck
      Completion = $completion
    }
  }

  foreach ($row in @($deckRows | Sort-Object `
      @{ Expression = { $_.Completion.CurrentPercent }; Descending = $true }, `
      @{ Expression = { [string]$_.Deck.label }; Descending = $false })) {
    $deck = $row.Deck
    $completion = $row.Completion

    $button = New-Object System.Windows.Controls.Button
    $button.Tag = [string]$deck.id
    $button.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $button.Padding = [System.Windows.Thickness]::new(12, 7, 12, 7)
    $button.BorderThickness = [System.Windows.Thickness]::new(0)
    $button.Cursor = [System.Windows.Input.Cursors]::Hand
    $button.MinHeight = 48
    $button.MaxHeight = 54
    $button.MinWidth = 108

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
    $title.FontSize = 14
    $title.FontFamily = [System.Windows.Media.FontFamily]::new("Malgun Gothic")

    $sub = New-Object System.Windows.Controls.TextBlock
    $sub.Text = "완성도: $($completion.CurrentPercent)%"
    $sub.FontSize = 11
    $sub.Opacity = 0.92
    $sub.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
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

function Refresh-TargetDeckList {
  param(
    $Deck,
    $RunState
  )

  $panel = $window.FindName("TargetDeckPanel")
  $title = $window.FindName("TargetDeckTitle")
  $list = $window.FindName("TargetDeckList")
  $list.Children.Clear()

  if ($null -eq $Deck) {
    $panel.Visibility = "Collapsed"
    return
  }

  $panel.Visibility = "Visible"
  $currentSet = @{}
  foreach ($id in (ConvertTo-ObjectArray $RunState.DeckIds)) {
    $currentSet[[string]$id] = $true
  }

  $trackedIds = @(ConvertTo-ObjectArray $Deck.core) + @(ConvertTo-ObjectArray $Deck.support)
  $ownedCount = 0
  foreach ($id in $trackedIds) {
    if ($currentSet.ContainsKey([string]$id)) {
      $ownedCount += 1
    }
  }

  $title.Text = "$([string]$Deck.label) 목표 ($ownedCount/$($trackedIds.Count))"

  foreach ($id in $trackedIds) {
    $cardId = [string]$id
    $label = Get-CardLabel -Id $cardId
    $owned = $currentSet.ContainsKey($cardId)

    $row = New-Object System.Windows.Controls.TextBlock
    $row.Text = if ($owned) { "✓ $($label.NameKo)" } else { "□ $($label.NameKo)" }
    $row.FontSize = 11
    $row.Margin = [System.Windows.Thickness]::new(0, 0, 0, 3)
    $row.TextTrimming = "CharacterEllipsis"
    $row.FontFamily = [System.Windows.Media.FontFamily]::new("Malgun Gothic")
    $row.Foreground = if ($owned) {
      [System.Windows.Media.BrushConverter]::new().ConvertFromString("#86EFAC")
    } else {
      [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CBD5E1")
    }
    $null = $list.Children.Add($row)
  }

  $unmatched = @(ConvertTo-ObjectArray $Deck.unmatched_cards)
  if ($unmatched.Count -gt 0) {
    $divider = New-Object System.Windows.Controls.TextBlock
    $divider.Text = "공용/미등록"
    $divider.FontSize = 10
    $divider.Margin = [System.Windows.Thickness]::new(0, 7, 0, 3)
    $divider.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#94A3B8")
    $divider.FontFamily = [System.Windows.Media.FontFamily]::new("Malgun Gothic")
    $null = $list.Children.Add($divider)

    foreach ($name in $unmatched) {
      $row = New-Object System.Windows.Controls.TextBlock
      $row.Text = "· $([string]$name)"
      $row.FontSize = 10
      $row.Margin = [System.Windows.Thickness]::new(0, 0, 0, 2)
      $row.TextTrimming = "CharacterEllipsis"
      $row.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#64748B")
      $row.FontFamily = [System.Windows.Media.FontFamily]::new("Malgun Gothic")
      $null = $list.Children.Add($row)
    }
  }
}

function Refresh-CombatPanel {
  param($CombatState)

  $panel = $window.FindName("CombatPanel")
  $title = $window.FindName("CombatTitle")
  $subTitle = $window.FindName("CombatSubTitle")
  $list = $window.FindName("CombatPlayerList")
  $list.Children.Clear()

  $players = @(ConvertTo-ObjectArray $CombatState.Players | Where-Object { [int]$_.total_damage -gt 0 -or [int]$_.current_turn_damage -gt 0 })
  if (-not $CombatState.Active -and $players.Count -eq 0) {
    $panel.Visibility = "Collapsed"
    return
  }

  $panel.Visibility = "Visible"
  $title.Text = if ($CombatState.Active) { "Target / Damage Report" } else { "Last Combat Report" }
  $subTitle.Text = if ($CombatState.Active) { "TURN $($CombatState.Turn)" } else { "ENDED · TURN $($CombatState.Turn)" }

  if ($players.Count -eq 0) {
    $empty = New-Object System.Windows.Controls.TextBlock
    $empty.Text = "딜 기록 대기 중"
    $empty.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#94A3B8")
    $empty.FontSize = 11
    $empty.FontFamily = [System.Windows.Media.FontFamily]::new("Malgun Gothic")
    $null = $list.Children.Add($empty)
    return
  }

  $totalDamageSum = 0
  $turnDamageSum = 0
  $specialDamageSum = 0
  $hpDamageSum = 0
  $blockedDamageSum = 0
  $turnsTaken = 0
  foreach ($player in $players) {
    $totalDamageSum += [int]$player.total_damage
    $turnDamageSum += [int]$player.current_turn_damage
    $specialDamageSum += [int]$player.total_special_damage
    $hpDamageSum += [int]$player.total_hp_damage
    $blockedDamageSum += [int]$player.total_blocked_damage
    $turnsTaken = [math]::Max($turnsTaken, [int]$player.turns_taken)
  }
  if ($turnsTaken -le 0) { $turnsTaken = [math]::Max(1, [int]$CombatState.Turn) }
  $avgDamage = if ($turnsTaken -le 0) { 0 } else { [math]::Round($totalDamageSum / [double]$turnsTaken, 1) }
  $barWidth = [math]::Max(10, [math]::Min(320, [math]::Round(320 * ($totalDamageSum / [double][math]::Max(1, $totalDamageSum)))))

  $summary = New-Object System.Windows.Controls.Grid
  $summary.Height = 68
  $summary.Margin = [System.Windows.Thickness]::new(0, 0, 0, 1)
  $summary.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#D9141B2E")

  $canvas = New-Object System.Windows.Controls.Canvas
  $canvas.Margin = [System.Windows.Thickness]::new(8, 8, 8, 8)

  $avgText = New-Object System.Windows.Controls.TextBlock
  $avgText.Text = "AVG DMG  $avgDamage"
  $avgText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FDE68A")
  $avgText.FontSize = 11
  $avgText.FontWeight = "Bold"
  $avgText.FontFamily = [System.Windows.Media.FontFamily]::new("Consolas")
  [System.Windows.Controls.Canvas]::SetLeft($avgText, 0)
  [System.Windows.Controls.Canvas]::SetTop($avgText, 0)
  $null = $canvas.Children.Add($avgText)

  $totalLabel = New-Object System.Windows.Controls.TextBlock
  $totalLabel.Text = "TOTAL $totalDamageSum"
  $totalLabel.Foreground = [System.Windows.Media.Brushes]::White
  $totalLabel.FontSize = 12
  $totalLabel.FontWeight = "Bold"
  $totalLabel.FontFamily = [System.Windows.Media.FontFamily]::new("Consolas")
  [System.Windows.Controls.Canvas]::SetLeft($totalLabel, 232)
  [System.Windows.Controls.Canvas]::SetTop($totalLabel, 0)
  $null = $canvas.Children.Add($totalLabel)

  $track = New-Object System.Windows.Shapes.Rectangle
  $track.Width = 320
  $track.Height = 18
  $track.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#334155")
  [System.Windows.Controls.Canvas]::SetLeft($track, 0)
  [System.Windows.Controls.Canvas]::SetTop($track, 25)
  $null = $canvas.Children.Add($track)

  $bar = New-Object System.Windows.Shapes.Rectangle
  $bar.Width = $barWidth
  $bar.Height = 18
  $bar.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F70A6C")
  [System.Windows.Controls.Canvas]::SetLeft($bar, 0)
  [System.Windows.Controls.Canvas]::SetTop($bar, 25)
  $null = $canvas.Children.Add($bar)

  $detail = New-Object System.Windows.Controls.TextBlock
  $detail.Text = "이번 턴 $turnDamageSum   HP $hpDamageSum   방어 $blockedDamageSum   특수 $specialDamageSum"
  $detail.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CBD5E1")
  $detail.FontSize = 10
  $detail.FontFamily = [System.Windows.Media.FontFamily]::new("Malgun Gothic")
  [System.Windows.Controls.Canvas]::SetLeft($detail, 0)
  [System.Windows.Controls.Canvas]::SetTop($detail, 46)
  $null = $canvas.Children.Add($detail)

  $summary.Children.Add($canvas) | Out-Null
  $null = $list.Children.Add($summary)
}

function Refresh-Overlay {
  Write-RuntimeStatus -State "refreshing" -Message "Rendering overlay frame."

  $run = Get-RunState
  $reward = Get-RewardState
  $combat = Get-CombatState
  $combatPlayers = @(ConvertTo-ObjectArray $combat.Players | Where-Object { [int]$_.total_damage -gt 0 -or [int]$_.current_turn_damage -gt 0 })
  $hasCombatPanel = $combat.Active -or $combatPlayers.Count -gt 0
  if (-not $reward.IsActive -and -not $hasCombatPanel) {
    if ($window.IsVisible) {
      $window.Hide()
    }
    $script:LastRenderHash = ""
    Write-RuntimeStatus -State "hidden" -Message ("Waiting for card screen. reason={0}; cards={1}" -f $reward.Reason, $reward.CardIds.Count)
    return
  }

  $hasGameBounds = Update-OverlayBounds

  if ($hasCombatPanel) {
    Refresh-CombatPanel -CombatState $combat
  } else {
    $window.FindName("CombatPanel").Visibility = "Collapsed"
  }

  if ($hasCombatPanel -and -not $reward.IsActive) {
    $window.FindName("CardGrid").Visibility = "Collapsed"
    $window.FindName("TargetDeckPanel").Visibility = "Collapsed"
    $window.FindName("DeckSelectorPanel").Visibility = "Collapsed"
    $window.FindName("StateSummaryText").Visibility = "Collapsed"
    $window.FindName("DeckSummaryText").Text = if ($combat.Active) { "전투 기록 중" } else { "마지막 전투 기록" }
    $state = if ($combat.Active) { "combat" } else { "combat_result" }
    Write-RuntimeStatus -State $state -Message ("Combat turn={0}; players={1}; active={2}; bounds={3}" -f $combat.Turn, $combatPlayers.Count, $combat.Active, $hasGameBounds)
    return
  }

  $window.FindName("CardGrid").Visibility = "Visible"
  $window.FindName("TargetDeckPanel").Visibility = "Visible"
  $window.FindName("DeckSelectorPanel").Visibility = "Visible"

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
    $deckSummaryText.Text = "$([string]$selectedDeck.label) · 완성도 $($overall.CurrentPercent)%"
  }

  $stateSummaryText.Text = "보상 $($reward.CardIds.Count)장 · 현재 덱 $($run.DeckIds.Count)장 · 유물 $($run.RelicIds.Count)개 · 갱신 $($reward.UpdatedAt)"

  Refresh-DeckButtons -RunState $run
  Refresh-TargetDeckList -Deck $selectedDeck -RunState $run

  $recommendationById = @{}
  if ($null -ne $selectedDeck) {
    $selectedLookup = Get-DeckCardLookup -Deck $selectedDeck
    $recommendations = @()
    foreach ($rewardCardId in (ConvertTo-ObjectArray $reward.CardIds)) {
      $cardIdText = [string]$rewardCardId
      if ([string]::IsNullOrWhiteSpace($cardIdText)) {
        continue
      }

      $completion = Get-DeckCompletion -Deck $selectedDeck -CurrentDeckIds $run.DeckIds -PickedCardId $cardIdText
      $role = if ($selectedLookup.ContainsKey($cardIdText)) { [string]$selectedLookup[$cardIdText] } else { "" }
      $roleWeight = if ($role -eq "core") { 2 } elseif ($role -eq "support") { 1 } else { 0 }
      if ([int]$completion.DeltaPercent -le 0 -and $roleWeight -eq 0) {
        continue
      }

      $recommendations += [pscustomobject]@{
        CardId = $cardIdText
        DeltaPercent = [int]$completion.DeltaPercent
        AfterPercent = [int]$completion.AfterPercent
        RoleWeight = $roleWeight
      }
    }

    $rank = 1
    foreach ($item in @($recommendations | Sort-Object `
        @{ Expression = "DeltaPercent"; Descending = $true }, `
        @{ Expression = "RoleWeight"; Descending = $true }, `
        @{ Expression = "AfterPercent"; Descending = $true })) {
      $item | Add-Member -NotePropertyName Rank -NotePropertyValue $rank -Force
      $recommendationById[$item.CardId] = $item
      $rank += 1
    }
  }

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
      "선택한 덱의 핵심 카드"
    } elseif ($selectedRole -eq "support") {
      "선택한 덱의 보조 카드"
    } else {
      "선택 덱과 직접 연관 없음"
    }

    $hintText = if ($tags.Count -gt 0) {
      "포함 덱: " + (($tags | ForEach-Object { $_.Label }) -join ", ")
    } else {
      "등록된 덱 태그가 없습니다."
    }

    $recommendation = if ($recommendationById.ContainsKey($cardId)) { $recommendationById[$cardId] } else { $null }
    if ($null -ne $recommendation -and $recommendation.Rank -eq 1) {
      if ($completion.DeltaPercent -gt 0) {
        $hintText = "가장 추천: 완성도 상승폭이 가장 큽니다. " + $hintText
      } else {
        $hintText = "선택한 덱 구성 카드입니다. " + $hintText
      }
    }

    $cardInfo = [pscustomobject]@{
      Label = $label
      Tags = $tags
      RoleText = $roleText
      HintText = $hintText
      SelectedDeckLabel = if ($null -ne $selectedDeck) { [string]$selectedDeck.label } else { "Selected deck" }
      Rank = if ($null -ne $recommendation) { [int]$recommendation.Rank } else { 0 }
      IsBestPick = ($null -ne $recommendation -and [int]$recommendation.Rank -eq 1)
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
