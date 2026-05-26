# Slay the Spire 2 Overlay Deck Tracker

RewardBridgeExport reads Slay the Spire 2 reward/combat data and drives a PowerShell overlay for Necrobinder deck recommendations and combat damage tracking.

## Install

1. Copy `mods/RewardBridgeExport.dll` and `mods/RewardBridgeExport.json` into the game's `mods` folder.
2. Copy the `RewardBridgeExport` folder into the game root.
3. Run `RewardBridgeExport/start_reward_overlay.bat` to start the overlay controller.

## Build

The C# bridge source is in `build_tmp/RewardBridgeExport.cs`.

```powershell
$env:DOTNET_CLI_HOME = '<game>\.dotnet_home'
$env:NUGET_PACKAGES = '<game>\.nuget_packages'
<game>\.dotnet\dotnet.exe build build_tmp\RewardBridgeExport.csproj -p:RestoreConfigFile=build_tmp\NuGet.Config
```

The project expects the game assemblies under `data_sts2_windows_x86_64` when building from the game root.

## Runtime Files

The overlay writes temporary files such as `RewardBridgeExport.current.json`, `RewardBridgeExport.combat.json`, logs, pid files, and runtime status JSON. These are intentionally not tracked.
