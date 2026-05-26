using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text;
using HarmonyLib;
using MegaCrit.Sts2.Core.Modding;
using Godot;

namespace RewardBridgeExport
{
    [ModInitializer("Initialize")]
    public static class ModBootstrap
    {
        private static readonly object Sync = new object();
        private static readonly HashSet<string> CurrentCardIds = new HashSet<string>(StringComparer.Ordinal);
        private static readonly Dictionary<string, int> CurrentCardOrder = new Dictionary<string, int>(StringComparer.Ordinal);
        private static readonly UTF8Encoding Utf8NoBom = new UTF8Encoding(false);
        private static string _outputPath;
        private static string _combatOutputPath;
        private static string _logPath;
        private static bool _combatActive;
        private static int _combatTurn;
        private static bool _inPlayerTurn;
        private static string _currentTurnPlayerId;
        private static readonly Dictionary<string, CombatDamageStats> CombatStats = new Dictionary<string, CombatDamageStats>(StringComparer.Ordinal);

        public static void Initialize()
        {
            var modDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location) ?? AppContext.BaseDirectory;
            _outputPath = Path.Combine(modDir, "RewardBridgeExport.current.json");
            _combatOutputPath = Path.Combine(modDir, "RewardBridgeExport.combat.json");
            _logPath = Path.Combine(modDir, "RewardBridgeExport.log");

            Log("Patch target screen_ready=" + SafeMethodName(AccessTools.Method("MegaCrit.Sts2.Core.Nodes.Screens.CardSelection.NCardRewardSelectionScreen:_Ready")));
            Log("Patch target screen_exit=" + SafeMethodName(AccessTools.Method("MegaCrit.Sts2.Core.Nodes.Screens.CardSelection.NCardRewardSelectionScreen:_ExitTree")));
            Log("Patch target button_ready=" + SafeMethodName(AccessTools.Method("MegaCrit.Sts2.Core.Nodes.Screens.CardSelection.NCardRewardAlternativeButton:_Ready")));
            Log("Patch target hook_after_modify=" + SafeMethodName(AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:AfterModifyingCardRewardOptions")));
            Log("Patch target combat_before_start=" + SafeMethodName(AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:BeforeCombatStart")));
            Log("Patch target combat_after_end=" + SafeMethodName(AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:AfterCombatEnd")));
            Log("Patch target combat_player_turn=" + SafeMethodName(AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:AfterPlayerTurnStart")));
            Log("Patch target combat_turn_end=" + SafeMethodName(AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:AfterTurnEnd")));
            Log("Patch target combat_damage_given=" + SafeMethodName(AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:AfterDamageGiven")));
            Log("Patch target combat_damage_received=" + SafeMethodName(AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:AfterDamageReceived")));
            Log("Patch target combat_death=" + SafeMethodName(AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:AfterDeath")));
            Log("Patch target combat_attack=" + SafeMethodName(AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:AfterAttack")));

            var harmony = new Harmony("RewardBridgeExport");
            harmony.PatchAll(Assembly.GetExecutingAssembly());
            Log("Initialized.");
            WriteCombatStats("initialized");
        }

        private static string SafeMethodName(MethodBase method)
        {
            return method == null ? "<null>" : method.DeclaringType.FullName + "::" + method.Name;
        }

        private static void ResetCards(string reason)
        {
            lock (Sync)
            {
                CurrentCardIds.Clear();
                CurrentCardOrder.Clear();
                WriteCurrentCards(reason);
            }
        }

        private static void CaptureFromObject(object source, string reason)
        {
            try
            {
                Log("Capture start reason=" + reason + " type=" + (source == null ? "<null>" : source.GetType().FullName));
                var found = new HashSet<string>(StringComparer.Ordinal);
                CollectKnownRewardCards(source, found);
                CollectCardIds(source, found, 0, new HashSet<object>(ReferenceEqualityComparer.Instance));

                if (found.Count == 0)
                {
                    Log("Capture found no cards for reason=" + reason);
                    return;
                }

                lock (Sync)
                {
                    var changed = false;
                    foreach (var cardId in found)
                    {
                        if (CurrentCardIds.Add(cardId))
                        {
                            changed = true;
                        }
                    }

                    var orderMap = new Dictionary<string, int>(StringComparer.Ordinal);
                    var sourceNode = source as Node;
                    if (sourceNode != null)
                    {
                        var nextIndex = 0;
                        CollectCardOrderMap(sourceNode, orderMap, 0, ref nextIndex);
                    }
                    foreach (var pair in orderMap)
                    {
                        CurrentCardOrder[pair.Key] = pair.Value;
                    }

                    if (changed || orderMap.Count > 0)
                    {
                        WriteCurrentCards(reason);
                    }
                }
            }
            catch (Exception ex)
            {
                Log("Capture failed: " + ex);
            }
        }

        private static void CollectKnownRewardCards(object source, ISet<string> found)
        {
            if (source == null)
            {
                return;
            }

            try
            {
                var type = source.GetType();

                var optionsField = type.GetField("_options", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                if (optionsField != null)
                {
                    var options = optionsField.GetValue(source) as IEnumerable;
                    if (options != null)
                    {
                        foreach (var option in options)
                        {
                            CollectCardIds(option, found, 0, new HashSet<object>(ReferenceEqualityComparer.Instance));
                        }
                    }
                }

                var node = source as Node;
                if (node != null)
                {
                    CollectCardIdsFromNodeNames(node, found, 0);
                }
            }
            catch (Exception ex)
            {
                Log("CollectKnownRewardCards failed: " + ex);
            }
        }

        private static void CollectCardIdsFromNodeNames(Node node, ISet<string> found, int depth)
        {
            if (node == null || depth > 5)
            {
                return;
            }

            var nodeName = node.Name.ToString();
            const string holderPrefix = "GridCardHolder-";
            if (nodeName.StartsWith(holderPrefix, StringComparison.Ordinal))
            {
                var suffix = nodeName.Substring(holderPrefix.Length);
                if (!string.IsNullOrEmpty(suffix))
                {
                    var cardId = suffix;
                    if (suffix.StartsWith("CARD_", StringComparison.Ordinal))
                    {
                        cardId = "CARD." + suffix.Substring("CARD_".Length);
                    }

                    found.Add(cardId);
                }
            }

            for (var i = 0; i < node.GetChildCount(); i++)
            {
                CollectCardIdsFromNodeNames(node.GetChild(i), found, depth + 1);
            }
        }

        private static void CollectCardOrderMap(Node node, IDictionary<string, int> orderMap, int depth, ref int nextIndex)
        {
            if (node == null || depth > 5)
            {
                return;
            }

            var nodeName = node.Name.ToString();
            const string holderPrefix = "GridCardHolder-";
            if (nodeName.StartsWith(holderPrefix, StringComparison.Ordinal))
            {
                var suffix = nodeName.Substring(holderPrefix.Length);
                if (!string.IsNullOrEmpty(suffix))
                {
                    var cardId = suffix.StartsWith("CARD_", StringComparison.Ordinal)
                        ? "CARD." + suffix.Substring("CARD_".Length)
                        : suffix;

                    orderMap[cardId] = nextIndex++;
                    Log("Order hint " + cardId + " index=" + orderMap[cardId]);
                }
            }

            for (var i = 0; i < node.GetChildCount(); i++)
            {
                CollectCardOrderMap(node.GetChild(i), orderMap, depth + 1, ref nextIndex);
            }
        }

        private static void WriteCurrentCards(string reason)
        {
            try
            {
                var ordered = CurrentCardIds
                    .OrderBy(id => CurrentCardOrder.ContainsKey(id) ? CurrentCardOrder[id] : int.MaxValue)
                    .ThenBy(id => id, StringComparer.Ordinal)
                    .ToArray();
                var builder = new StringBuilder();
                builder.AppendLine("{");
                builder.AppendFormat("  \"updated_at\": \"{0:O}\",\n", DateTime.UtcNow);
                builder.AppendFormat("  \"reason\": \"{0}\",\n", Escape(reason));
                builder.AppendFormat("  \"count\": {0},\n", ordered.Length);
                builder.AppendLine("  \"card_ids\": [");
                for (var i = 0; i < ordered.Length; i++)
                {
                    builder.AppendFormat("    \"{0}\"{1}\n", Escape(ordered[i]), i == ordered.Length - 1 ? string.Empty : ",");
                }
                builder.AppendLine("  ]");
                builder.AppendLine("}");
                var tempPath = _outputPath + ".tmp";
                File.WriteAllText(tempPath, builder.ToString(), Utf8NoBom);
                if (File.Exists(_outputPath))
                {
                    File.Delete(_outputPath);
                }

                File.Move(tempPath, _outputPath);
                Log("Wrote " + ordered.Length + " reward cards from " + reason + ": " + string.Join(", ", ordered));
            }
            catch (Exception ex)
            {
                Log("Write failed: " + ex);
            }
        }

        private static void StartCombat(object[] args)
        {
            lock (Sync)
            {
                _combatActive = true;
                _combatTurn = 0;
                _inPlayerTurn = false;
                _currentTurnPlayerId = null;
                CombatStats.Clear();
                WriteCombatStats("combat_start");
            }
        }

        private static void EndCombat(object[] args)
        {
            lock (Sync)
            {
                _combatActive = false;
                _inPlayerTurn = false;
                _currentTurnPlayerId = null;
                WriteCombatStats("combat_end");
            }
        }

        private static void StartPlayerTurn(object[] args)
        {
            lock (Sync)
            {
                _combatActive = true;
                _inPlayerTurn = true;
                _combatTurn += 1;
                _currentTurnPlayerId = ExtractTurnPlayerId(args);
                var stats = GetCombatStats(_currentTurnPlayerId);
                stats.DisplayName = DisplayNameForPlayer(_currentTurnPlayerId);
                stats.TurnsTaken += 1;
                stats.CurrentTurnAttemptedDamage = 0;
                stats.CurrentTurnBlockedDamage = 0;
                stats.CurrentTurnHpDamage = 0;
                stats.CurrentTurnSpecialDamage = 0;
                WriteCombatStats("player_turn_start");
            }
        }

        private static void AddDamageEvent(object[] args, string reason)
        {
            try
            {
                var metrics = ExtractDamageMetrics(args);
                if (metrics.TotalContribution <= 0)
                {
                    Log("Combat damage ignored reason=" + reason + " argCount=" + (args == null ? 0 : args.Length));
                    return;
                }

                lock (Sync)
                {
                    _combatActive = true;
                    var isSpecial = IsSpecialDamage(args);
                    if (IsDamageToPlayer(args))
                    {
                        Log("Combat damage ignored reason=" + reason + " target=player");
                        return;
                    }

                    var sourcePlayerId = ExtractSourcePlayerId(args);
                    if (string.IsNullOrEmpty(sourcePlayerId) && _inPlayerTurn && !string.IsNullOrEmpty(_currentTurnPlayerId))
                    {
                        sourcePlayerId = _currentTurnPlayerId;
                    }

                    if (string.IsNullOrEmpty(sourcePlayerId))
                    {
                        Log("Combat damage ignored reason=" + reason + " source=unknown");
                        return;
                    }

                    if (!_inPlayerTurn && !isSpecial)
                    {
                        Log("Combat damage ignored reason=" + reason + " source=non_player_turn");
                        return;
                    }

                    var stats = GetCombatStats(sourcePlayerId);
                    stats.DisplayName = DisplayNameForPlayer(sourcePlayerId);

                    stats.CurrentTurnAttemptedDamage += metrics.AttemptedDamage;
                    stats.CurrentTurnBlockedDamage += metrics.BlockedDamage;
                    stats.CurrentTurnHpDamage += metrics.HpDamage;
                    stats.TotalAttemptedDamage += metrics.AttemptedDamage;
                    stats.TotalBlockedDamage += metrics.BlockedDamage;
                    stats.TotalHpDamage += metrics.HpDamage;

                    if (isSpecial)
                    {
                        stats.CurrentTurnSpecialDamage += metrics.TotalContribution;
                        stats.TotalSpecialDamage += metrics.TotalContribution;
                    }

                    stats.Events += 1;
                    WriteCombatStats(reason);
                }
            }
            catch (Exception ex)
            {
                Log("Combat damage failed reason=" + reason + ": " + ex);
            }
        }

        private static CombatDamageStats GetCombatStats(string playerId)
        {
            if (string.IsNullOrEmpty(playerId))
            {
                playerId = "local";
            }

            CombatDamageStats stats;
            if (!CombatStats.TryGetValue(playerId, out stats))
            {
                stats = new CombatDamageStats { PlayerId = playerId, DisplayName = playerId };
                CombatStats[playerId] = stats;
            }

            return stats;
        }

        private static string DisplayNameForPlayer(string playerId)
        {
            if (string.IsNullOrEmpty(playerId))
            {
                return "Player";
            }

            if (playerId == "local")
            {
                return "Local Player";
            }

            return "Player " + playerId;
        }

        private static DamageMetrics ExtractDamageMetrics(object[] args)
        {
            var metrics = new DamageMetrics();
            var visited = new HashSet<object>(ReferenceEqualityComparer.Instance);
            if (args != null)
            {
                foreach (var arg in args)
                {
                CollectDamageMetrics(arg, metrics, 0, visited);
                }
            }

            if (metrics.AttemptedDamage <= 0)
            {
                metrics.AttemptedDamage = metrics.HpDamage + metrics.BlockedDamage;
            }

            return metrics;
        }

        private static void CollectDamageMetrics(object value, DamageMetrics metrics, int depth, ISet<object> visited)
        {
            if (value == null || depth > 1)
            {
                return;
            }

            var type = value.GetType();
            if (!type.IsValueType)
            {
                if (visited.Contains(value))
                {
                    return;
                }

                visited.Add(value);
            }

            if (type.IsPrimitive || type.IsEnum || value is string || value is decimal || value is DateTime)
            {
                return;
            }

            foreach (var property in type.GetProperties(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
            {
                if (property.GetIndexParameters().Length != 0 || !property.CanRead)
                {
                    continue;
                }

                object propertyValue;
                try
                {
                    propertyValue = property.GetValue(value);
                }
                catch
                {
                    continue;
                }

                AddDamageMetric(property.Name, propertyValue, metrics);
                if (depth == 0)
                {
                    CollectDamageMetrics(propertyValue, metrics, depth + 1, visited);
                }
            }

            foreach (var field in type.GetFields(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
            {
                object fieldValue;
                try
                {
                    fieldValue = field.GetValue(value);
                }
                catch
                {
                    continue;
                }

                AddDamageMetric(field.Name, fieldValue, metrics);
                if (depth == 0)
                {
                    CollectDamageMetrics(fieldValue, metrics, depth + 1, visited);
                }
            }
        }

        private static void AddDamageMetric(string name, object value, DamageMetrics metrics)
        {
            int amount;
            if (!TryGetInt(value, out amount) || amount <= 0)
            {
                return;
            }

            var lower = (name ?? string.Empty).ToLowerInvariant();
            if (lower.Contains("blocked"))
            {
                metrics.BlockedDamage = Math.Max(metrics.BlockedDamage, amount);
                return;
            }

            if (lower.Contains("unblocked")
                || lower.Contains("hplost")
                || lower.Contains("hp_lost")
                || lower.Contains("healthlost")
                || lower.Contains("health_lost")
                || lower.Contains("hpdamage")
                || lower.Contains("hp_damage"))
            {
                metrics.HpDamage = Math.Max(metrics.HpDamage, amount);
                return;
            }

            if (lower == "damage"
                || lower.EndsWith("damage")
                || lower.Contains("damageamount")
                || lower.Contains("damage_amount")
                || lower == "amount"
                || lower == "value")
            {
                metrics.AttemptedDamage = Math.Max(metrics.AttemptedDamage, amount);
            }
        }

        private static bool TryGetInt(object value, out int amount)
        {
            amount = 0;
            if (value is int)
            {
                amount = (int)value;
                return true;
            }

            if (value is long)
            {
                amount = (int)Math.Min(int.MaxValue, (long)value);
                return true;
            }

            if (value is float)
            {
                amount = (int)Math.Round((float)value);
                return true;
            }

            if (value is double)
            {
                amount = (int)Math.Round((double)value);
                return true;
            }

            return false;
        }

        private static string ExtractPlayerId(object[] args)
        {
            var visited = new HashSet<object>(ReferenceEqualityComparer.Instance);
            if (args != null)
            {
                foreach (var arg in args)
                {
                    var found = FindPlayerId(arg, 0, visited);
                    if (!string.IsNullOrEmpty(found))
                    {
                        return found;
                    }
                }
            }

            return "local";
        }

        private static string FindPlayerId(object value, int depth, ISet<object> visited)
        {
            if (value == null || depth > 1)
            {
                return null;
            }

            var text = value as string;
            if (text != null)
            {
                return null;
            }

            var type = value.GetType();
            if (!type.IsValueType)
            {
                if (visited.Contains(value))
                {
                    return null;
                }

                visited.Add(value);
            }

            if (type.IsPrimitive || type.IsEnum || value is decimal || value is DateTime)
            {
                return null;
            }

            foreach (var property in type.GetProperties(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
            {
                if (property.GetIndexParameters().Length != 0 || !property.CanRead)
                {
                    continue;
                }

                object propertyValue;
                try
                {
                    propertyValue = property.GetValue(value);
                }
                catch
                {
                    continue;
                }

                var id = PlayerIdFromMember(property.Name, propertyValue);
                if (!string.IsNullOrEmpty(id))
                {
                    return id;
                }

                if (depth == 0)
                {
                    id = FindPlayerId(propertyValue, depth + 1, visited);
                    if (!string.IsNullOrEmpty(id))
                    {
                        return id;
                    }
                }
            }

            foreach (var field in type.GetFields(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
            {
                object fieldValue;
                try
                {
                    fieldValue = field.GetValue(value);
                }
                catch
                {
                    continue;
                }

                var id = PlayerIdFromMember(field.Name, fieldValue);
                if (!string.IsNullOrEmpty(id))
                {
                    return id;
                }

                if (depth == 0)
                {
                    id = FindPlayerId(fieldValue, depth + 1, visited);
                    if (!string.IsNullOrEmpty(id))
                    {
                        return id;
                    }
                }
            }

            return null;
        }

        private static string PlayerIdFromMember(string name, object value)
        {
            var lower = (name ?? string.Empty).ToLowerInvariant();
            if (lower.IndexOf("player", StringComparison.Ordinal) < 0 && lower.IndexOf("owner", StringComparison.Ordinal) < 0)
            {
                return null;
            }

            if (value is string)
            {
                return (string)value;
            }

            if (value is bool)
            {
                return null;
            }

            if (value != null && (value.GetType().IsPrimitive || value.GetType().IsEnum))
            {
                return Convert.ToString(value);
            }

            return null;
        }

        private static bool IsSpecialDamage(object[] args)
        {
            return IsPoisonDamage(args) || IsDoomDamage(args);
        }

        private static bool IsPoisonDamage(object[] args)
        {
            return ContainsDamageMarker(args, "Poison");
        }

        private static bool IsDoomDamage(object[] args)
        {
            return ContainsDamageMarker(args, "Doom");
        }

        private static bool IsDamageToPlayer(object[] args)
        {
            if (args == null)
            {
                return false;
            }

            var visited = new HashSet<object>(ReferenceEqualityComparer.Instance);
            foreach (var arg in args)
            {
                if (IsPlayerTargetMember("arg", arg, 0, visited))
                {
                    return true;
                }
            }

            return false;
        }

        private static bool IsPlayerDamageSource(object[] args)
        {
            return !string.IsNullOrEmpty(ExtractSourcePlayerId(args));
        }

        private static string ExtractTurnPlayerId(object[] args)
        {
            var sourceId = ExtractSourcePlayerId(args);
            if (!string.IsNullOrEmpty(sourceId))
            {
                return sourceId;
            }

            var broadId = ExtractPlayerId(args);
            return string.IsNullOrEmpty(broadId) ? "local" : broadId;
        }

        private static string ExtractSourcePlayerId(object[] args)
        {
            if (args == null)
            {
                return null;
            }

            var visited = new HashSet<object>(ReferenceEqualityComparer.Instance);
            foreach (var arg in args)
            {
                var id = FindSourcePlayerId("arg", arg, 0, visited);
                if (!string.IsNullOrEmpty(id))
                {
                    return id;
                }
            }

            return null;
        }

        private static string FindSourcePlayerId(string memberName, object value, int depth, ISet<object> visited)
        {
            if (value == null || depth > 2)
            {
                return null;
            }

            var lowerMember = (memberName ?? string.Empty).ToLowerInvariant();
            var isTargetSlot = lowerMember.Contains("target")
                || lowerMember.Contains("victim")
                || lowerMember.Contains("receiver")
                || lowerMember.Contains("recipient")
                || lowerMember.Contains("defender")
                || lowerMember.Contains("damaged");
            if (isTargetSlot)
            {
                return null;
            }

            var isSourceSlot = lowerMember.Contains("source")
                || lowerMember.Contains("attacker")
                || lowerMember.Contains("owner")
                || lowerMember.Contains("caster")
                || lowerMember.Contains("instigator")
                || lowerMember.Contains("origin")
                || lowerMember.Contains("player");

            var directId = PlayerIdFromScopedMember(memberName, value, isSourceSlot);
            if (!string.IsNullOrEmpty(directId))
            {
                return directId;
            }

            var type = value.GetType();
            if (!type.IsValueType)
            {
                if (visited.Contains(value))
                {
                    return null;
                }

                visited.Add(value);
            }

            if (type.IsPrimitive || type.IsEnum || value is string || value is decimal || value is DateTime)
            {
                return null;
            }

            foreach (var property in type.GetProperties(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
            {
                if (property.GetIndexParameters().Length != 0 || !property.CanRead)
                {
                    continue;
                }

                object propertyValue;
                try
                {
                    propertyValue = property.GetValue(value);
                }
                catch
                {
                    continue;
                }

                var id = FindSourcePlayerId(property.Name, propertyValue, depth + 1, visited);
                if (!string.IsNullOrEmpty(id))
                {
                    return id;
                }
            }

            foreach (var field in type.GetFields(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
            {
                object fieldValue;
                try
                {
                    fieldValue = field.GetValue(value);
                }
                catch
                {
                    continue;
                }

                var id = FindSourcePlayerId(field.Name, fieldValue, depth + 1, visited);
                if (!string.IsNullOrEmpty(id))
                {
                    return id;
                }
            }

            return null;
        }

        private static string PlayerIdFromScopedMember(string name, object value, bool isSourceSlot)
        {
            if (value == null)
            {
                return null;
            }

            var lower = (name ?? string.Empty).ToLowerInvariant();
            var looksLikePlayerId = lower == "playerid"
                || lower == "player_id"
                || lower == "ownerid"
                || lower == "owner_id"
                || lower == "sourceplayerid"
                || lower == "source_player_id"
                || lower == "attackerplayerid"
                || lower == "attacker_player_id";

            if (!isSourceSlot && !looksLikePlayerId)
            {
                return null;
            }

            var text = value as string;
            if (!string.IsNullOrWhiteSpace(text))
            {
                return text;
            }

            if (value is bool)
            {
                return null;
            }

            if (value.GetType().IsPrimitive || value.GetType().IsEnum)
            {
                return Convert.ToString(value);
            }

            var typeName = value.GetType().FullName ?? string.Empty;
            if (typeName.IndexOf("Player", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return PlayerIdFromObject(value);
            }

            return null;
        }

        private static string PlayerIdFromObject(object value)
        {
            if (value == null)
            {
                return null;
            }

            var type = value.GetType();
            foreach (var propertyName in new[] { "PlayerId", "PlayerID", "Id", "ID", "NetId", "PeerId", "Index", "Seat" })
            {
                var property = type.GetProperty(propertyName, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                if (property == null || property.GetIndexParameters().Length != 0 || !property.CanRead)
                {
                    continue;
                }

                try
                {
                    var id = ConvertPlayerIdValue(property.GetValue(value));
                    if (!string.IsNullOrEmpty(id))
                    {
                        return id;
                    }
                }
                catch
                {
                }
            }

            foreach (var fieldName in new[] { "PlayerId", "playerId", "_playerId", "Id", "id", "_id", "NetId", "PeerId", "Index", "Seat" })
            {
                var field = type.GetField(fieldName, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                if (field == null)
                {
                    continue;
                }

                try
                {
                    var id = ConvertPlayerIdValue(field.GetValue(value));
                    if (!string.IsNullOrEmpty(id))
                    {
                        return id;
                    }
                }
                catch
                {
                }
            }

            return "local";
        }

        private static string ConvertPlayerIdValue(object value)
        {
            if (value == null || value is bool)
            {
                return null;
            }

            var text = value as string;
            if (!string.IsNullOrWhiteSpace(text))
            {
                return text;
            }

            if (value.GetType().IsPrimitive || value.GetType().IsEnum)
            {
                return Convert.ToString(value);
            }

            return null;
        }

        private static bool IsPlayerSourceMember(string memberName, object value, int depth, ISet<object> visited)
        {
            if (value == null || depth > 1)
            {
                return false;
            }

            var type = value.GetType();
            var typeName = type.FullName ?? string.Empty;
            if (typeName.IndexOf("Card", StringComparison.OrdinalIgnoreCase) >= 0
                && typeName.IndexOf("Reward", StringComparison.OrdinalIgnoreCase) < 0)
            {
                return true;
            }

            var lowerMember = (memberName ?? string.Empty).ToLowerInvariant();
            var isSourceSlot = lowerMember.Contains("source")
                || lowerMember.Contains("attacker")
                || lowerMember.Contains("owner")
                || lowerMember.Contains("caster")
                || lowerMember.Contains("instigator")
                || lowerMember.Contains("origin")
                || lowerMember.Contains("player");

            var text = value as string;
            if (isSourceSlot)
            {
                if (typeName.IndexOf("Player", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    return true;
                }

                if (text != null && text.IndexOf("Player", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    return true;
                }
            }

            if (!type.IsValueType)
            {
                if (visited.Contains(value))
                {
                    return false;
                }

                visited.Add(value);
            }

            if (type.IsPrimitive || type.IsEnum || value is string || value is decimal || value is DateTime)
            {
                return false;
            }

            foreach (var property in type.GetProperties(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
            {
                if (property.GetIndexParameters().Length != 0 || !property.CanRead)
                {
                    continue;
                }

                object propertyValue;
                try
                {
                    propertyValue = property.GetValue(value);
                }
                catch
                {
                    continue;
                }

                if (IsPlayerSourceMember(property.Name, propertyValue, depth + 1, visited))
                {
                    return true;
                }
            }

            foreach (var field in type.GetFields(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
            {
                object fieldValue;
                try
                {
                    fieldValue = field.GetValue(value);
                }
                catch
                {
                    continue;
                }

                if (IsPlayerSourceMember(field.Name, fieldValue, depth + 1, visited))
                {
                    return true;
                }
            }

            return false;
        }

        private static bool IsPlayerTargetMember(string memberName, object value, int depth, ISet<object> visited)
        {
            if (value == null || depth > 1)
            {
                return false;
            }

            var lowerMember = (memberName ?? string.Empty).ToLowerInvariant();
            var isTargetSlot = lowerMember.Contains("target")
                || lowerMember.Contains("victim")
                || lowerMember.Contains("receiver")
                || lowerMember.Contains("recipient")
                || lowerMember.Contains("defender")
                || lowerMember.Contains("damaged")
                || lowerMember.Contains("creature");

            var type = value.GetType();
            var typeName = type.FullName ?? string.Empty;
            var text = value as string;
            if (isTargetSlot)
            {
                if (typeName.IndexOf("Player", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    return true;
                }

                if (text != null && text.IndexOf("Player", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    return true;
                }
            }

            if (!type.IsValueType)
            {
                if (visited.Contains(value))
                {
                    return false;
                }

                visited.Add(value);
            }

            if (type.IsPrimitive || type.IsEnum || value is string || value is decimal || value is DateTime)
            {
                return false;
            }

            foreach (var property in type.GetProperties(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
            {
                if (property.GetIndexParameters().Length != 0 || !property.CanRead)
                {
                    continue;
                }

                object propertyValue;
                try
                {
                    propertyValue = property.GetValue(value);
                }
                catch
                {
                    continue;
                }

                if (IsPlayerTargetMember(property.Name, propertyValue, depth + 1, visited))
                {
                    return true;
                }
            }

            foreach (var field in type.GetFields(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
            {
                object fieldValue;
                try
                {
                    fieldValue = field.GetValue(value);
                }
                catch
                {
                    continue;
                }

                if (IsPlayerTargetMember(field.Name, fieldValue, depth + 1, visited))
                {
                    return true;
                }
            }

            return false;
        }

        private static bool ContainsDamageMarker(object[] args, string marker)
        {
            if (args == null)
            {
                return false;
            }

            var visited = new HashSet<object>(ReferenceEqualityComparer.Instance);
            foreach (var arg in args)
            {
                if (ContainsSpecialDamageMarker(arg, marker, 0, visited))
                {
                    return true;
                }
            }

            return false;
        }

        private static bool ContainsSpecialDamageMarker(object value, string marker, int depth, ISet<object> visited)
        {
            if (value == null || depth > 1)
            {
                return false;
            }

            var type = value.GetType();
            var typeName = type.FullName ?? string.Empty;
            if (typeName.IndexOf(marker, StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return true;
            }

            if (!type.IsValueType)
            {
                if (visited.Contains(value))
                {
                    return false;
                }

                visited.Add(value);
            }

            if (type.IsPrimitive || type.IsEnum || value is decimal || value is DateTime)
            {
                return false;
            }

            var text = value as string;
            if (text != null)
            {
                return text.IndexOf(marker, StringComparison.OrdinalIgnoreCase) >= 0;
            }

            foreach (var property in type.GetProperties(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
            {
                if (property.GetIndexParameters().Length != 0 || !property.CanRead)
                {
                    continue;
                }

                if (property.Name.IndexOf(marker, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    return true;
                }

                object propertyValue;
                try
                {
                    propertyValue = property.GetValue(value);
                }
                catch
                {
                    continue;
                }

                if (ContainsSpecialDamageMarker(propertyValue, marker, depth + 1, visited))
                {
                    return true;
                }
            }

            foreach (var field in type.GetFields(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
            {
                if (field.Name.IndexOf(marker, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    return true;
                }

                object fieldValue;
                try
                {
                    fieldValue = field.GetValue(value);
                }
                catch
                {
                    continue;
                }

                if (ContainsSpecialDamageMarker(fieldValue, marker, depth + 1, visited))
                {
                    return true;
                }
            }

            return false;
        }

        private static void WriteCombatStats(string reason)
        {
            try
            {
                var builder = new StringBuilder();
                builder.AppendLine("{");
                builder.AppendFormat("  \"updated_at\": \"{0:O}\",\n", DateTime.UtcNow);
                builder.AppendFormat("  \"reason\": \"{0}\",\n", Escape(reason));
                builder.AppendFormat("  \"active\": {0},\n", _combatActive ? "true" : "false");
                builder.AppendFormat("  \"turn\": {0},\n", _combatTurn);
                builder.AppendLine("  \"players\": [");

                var index = 0;
                foreach (var stats in CombatStats.Values.OrderBy(s => s.PlayerId, StringComparer.Ordinal))
                {
                    if (index > 0)
                    {
                        builder.AppendLine(",");
                    }

                    var totalContribution = stats.TotalContributionDamage;
                    var currentContribution = stats.CurrentTurnContributionDamage;
                    var avg = stats.TurnsTaken <= 0 ? 0.0 : (double)totalContribution / stats.TurnsTaken;
                    builder.AppendLine("    {");
                    builder.AppendFormat("      \"player_id\": \"{0}\",\n", Escape(stats.PlayerId));
                    builder.AppendFormat("      \"name\": \"{0}\",\n", Escape(stats.DisplayName));
                    builder.AppendFormat("      \"turns_taken\": {0},\n", stats.TurnsTaken);
                    builder.AppendFormat("      \"current_turn_damage\": {0},\n", currentContribution);
                    builder.AppendFormat("      \"current_turn_attempted_damage\": {0},\n", stats.CurrentTurnAttemptedDamage);
                    builder.AppendFormat("      \"current_turn_blocked_damage\": {0},\n", stats.CurrentTurnBlockedDamage);
                    builder.AppendFormat("      \"current_turn_hp_damage\": {0},\n", stats.CurrentTurnHpDamage);
                    builder.AppendFormat("      \"current_turn_special_damage\": {0},\n", stats.CurrentTurnSpecialDamage);
                    builder.AppendFormat("      \"total_damage\": {0},\n", totalContribution);
                    builder.AppendFormat("      \"total_attempted_damage\": {0},\n", stats.TotalAttemptedDamage);
                    builder.AppendFormat("      \"total_blocked_damage\": {0},\n", stats.TotalBlockedDamage);
                    builder.AppendFormat("      \"total_hp_damage\": {0},\n", stats.TotalHpDamage);
                    builder.AppendFormat("      \"total_special_damage\": {0},\n", stats.TotalSpecialDamage);
                    builder.AppendFormat("      \"avg_damage_per_turn\": {0:0.##},\n", avg);
                    builder.AppendFormat("      \"events\": {0}\n", stats.Events);
                    builder.Append("    }");
                    index += 1;
                }

                builder.AppendLine();
                builder.AppendLine("  ]");
                builder.AppendLine("}");
                var tempPath = _combatOutputPath + ".tmp";
                File.WriteAllText(tempPath, builder.ToString(), Utf8NoBom);
                if (File.Exists(_combatOutputPath))
                {
                    File.Delete(_combatOutputPath);
                }

                File.Move(tempPath, _combatOutputPath);
            }
            catch (Exception ex)
            {
                Log("Write combat failed: " + ex);
            }
        }

        private static void CollectCardIds(object value, ISet<string> found, int depth, ISet<object> visited)
        {
            if (value == null || depth > 5)
            {
                return;
            }

            var text = value as string;
            if (text != null)
            {
                if (text.StartsWith("CARD.", StringComparison.Ordinal))
                {
                    found.Add(text);
                }

                return;
            }

            var type = value.GetType();
            if (!type.IsValueType)
            {
                if (visited.Contains(value))
                {
                    return;
                }

                visited.Add(value);
            }

            if (type.IsPrimitive || type.IsEnum || value is decimal || value is DateTime)
            {
                return;
            }

            var enumerable = value as IEnumerable;
            if (enumerable != null && !(value is IDictionary))
            {
                foreach (var item in enumerable)
                {
                    CollectCardIds(item, found, depth + 1, visited);
                }

                return;
            }

            foreach (var property in type.GetProperties(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
            {
                if (property.GetIndexParameters().Length != 0 || !property.CanRead)
                {
                    continue;
                }

                object propertyValue;
                try
                {
                    propertyValue = property.GetValue(value);
                }
                catch
                {
                    continue;
                }

                CollectCardIds(propertyValue, found, depth + 1, visited);

                if (property.Name == "Id" && propertyValue is string)
                {
                    var cardId = propertyValue as string;
                    if (!string.IsNullOrEmpty(cardId) && cardId.StartsWith("CARD.", StringComparison.Ordinal))
                    {
                        found.Add(cardId);
                    }
                }

                if ((property.Name.IndexOf("id", StringComparison.OrdinalIgnoreCase) >= 0
                        || property.Name.IndexOf("model", StringComparison.OrdinalIgnoreCase) >= 0)
                    && propertyValue is string)
                {
                    var namedId = propertyValue as string;
                    if (!string.IsNullOrEmpty(namedId) && namedId.StartsWith("CARD.", StringComparison.Ordinal))
                    {
                        found.Add(namedId);
                    }
                }
            }

            foreach (var field in type.GetFields(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
            {
                object fieldValue;
                try
                {
                    fieldValue = field.GetValue(value);
                }
                catch
                {
                    continue;
                }

                CollectCardIds(fieldValue, found, depth + 1, visited);

                if ((field.Name.IndexOf("id", StringComparison.OrdinalIgnoreCase) >= 0
                        || field.Name.IndexOf("model", StringComparison.OrdinalIgnoreCase) >= 0)
                    && fieldValue is string)
                {
                    var namedId = fieldValue as string;
                    if (!string.IsNullOrEmpty(namedId) && namedId.StartsWith("CARD.", StringComparison.Ordinal))
                    {
                        found.Add(namedId);
                    }
                }
            }
        }

        private static void DumpTopLevelMembers(object source, string reason)
        {
            try
            {
                if (source == null)
                {
                    Log("Dump skipped for " + reason + " because source is null.");
                    return;
                }

                var type = source.GetType();
                Log("Dump members for " + reason + " type=" + type.FullName);

                foreach (var property in type.GetProperties(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
                {
                    if (property.GetIndexParameters().Length != 0 || !property.CanRead)
                    {
                        continue;
                    }

                    try
                    {
                        var value = property.GetValue(source);
                        Log("  prop " + property.Name + " : " + property.PropertyType.FullName + " = " + DescribeValue(value));
                    }
                    catch (Exception ex)
                    {
                        Log("  prop " + property.Name + " : <error> " + ex.GetType().Name);
                    }
                }

                foreach (var field in type.GetFields(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
                {
                    try
                    {
                        var value = field.GetValue(source);
                        Log("  field " + field.Name + " : " + field.FieldType.FullName + " = " + DescribeValue(value));
                    }
                    catch (Exception ex)
                    {
                        Log("  field " + field.Name + " : <error> " + ex.GetType().Name);
                    }
                }
            }
            catch (Exception ex)
            {
                Log("Dump failed for " + reason + ": " + ex);
            }
        }

        private static void DumpNodeTree(object source, string reason, int maxDepth)
        {
            try
            {
                var node = source as Node;
                if (node == null)
                {
                    Log("Node dump skipped for " + reason + " because source is not a Godot.Node.");
                    return;
                }

                Log("Node tree for " + reason + ":");
                DumpNodeRecursive(node, 0, maxDepth);
            }
            catch (Exception ex)
            {
                Log("Node dump failed for " + reason + ": " + ex);
            }
        }

        private static void DumpNodeRecursive(Node node, int depth, int maxDepth)
        {
            if (node == null || depth > maxDepth)
            {
                return;
            }

            var indent = new string(' ', depth * 2);
            Log(indent + "- " + node.Name + " :: " + node.GetType().FullName);

            for (var i = 0; i < node.GetChildCount(); i++)
            {
                var child = node.GetChild(i);
                DumpNodeRecursive(child, depth + 1, maxDepth);
            }
        }

        private static string DescribeValue(object value)
        {
            if (value == null)
            {
                return "<null>";
            }

            var text = value as string;
            if (text != null)
            {
                return text;
            }

            if (value is IEnumerable && !(value is IDictionary))
            {
                return "<enumerable:" + value.GetType().FullName + ">";
            }

            return value.GetType().FullName;
        }

        private static string Escape(string text)
        {
            return (text ?? string.Empty)
                .Replace("\\", "\\\\")
                .Replace("\"", "\\\"");
        }

        private static void Log(string message)
        {
            try
            {
                File.AppendAllText(
                    _logPath,
                    string.Format("[{0:yyyy-MM-dd HH:mm:ss}] {1}{2}", DateTime.Now, message, System.Environment.NewLine));
            }
            catch
            {
            }
        }

        [HarmonyPatch]
        private static class RewardScreenReadyPatch
        {
            private static MethodBase TargetMethod()
            {
                return AccessTools.Method(
                    "MegaCrit.Sts2.Core.Nodes.Screens.CardSelection.NCardRewardSelectionScreen:_Ready");
            }

            private static void Postfix(object __instance)
            {
                Log("Reward screen _Ready fired.");
                DumpTopLevelMembers(__instance, "screen_ready");
                DumpNodeTree(__instance, "screen_ready", 3);
                ResetCards("screen_ready");
                CaptureFromObject(__instance, "screen_ready_scan");
            }
        }

        [HarmonyPatch]
        private static class RewardScreenExitPatch
        {
            private static MethodBase TargetMethod()
            {
                return AccessTools.Method(
                    "MegaCrit.Sts2.Core.Nodes.Screens.CardSelection.NCardRewardSelectionScreen:_ExitTree");
            }

            private static void Prefix()
            {
                Log("Reward screen _ExitTree fired.");
                ResetCards("screen_exit");
            }
        }

        [HarmonyPatch]
        private static class RewardButtonReadyPatch
        {
            private static MethodBase TargetMethod()
            {
                return AccessTools.Method(
                    "MegaCrit.Sts2.Core.Nodes.Screens.CardSelection.NCardRewardAlternativeButton:_Ready");
            }

            private static void Postfix(object __instance)
            {
                Log("Reward button _Ready fired.");
                DumpTopLevelMembers(__instance, "button_ready");
                CaptureFromObject(__instance, "button_ready");
            }
        }

        [HarmonyPatch]
        private static class HookAfterModifyingCardRewardOptionsPatch
        {
            private static MethodBase TargetMethod()
            {
                return AccessTools.Method(
                    "MegaCrit.Sts2.Core.Hooks.Hook:AfterModifyingCardRewardOptions");
            }

            private static void Prefix(object[] __args)
            {
                Log("Hook.AfterModifyingCardRewardOptions fired. argCount=" + (__args == null ? 0 : __args.Length));
                if (__args == null)
                {
                    return;
                }

                ResetCards("hook_before_capture");
                foreach (var arg in __args)
                {
                    Log("Hook arg type=" + (arg == null ? "<null>" : arg.GetType().FullName));
                    CaptureFromObject(arg, "hook_arg");
                }
            }
        }

        [HarmonyPatch]
        private static class HookBeforeCombatStartPatch
        {
            private static MethodBase TargetMethod()
            {
                return AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:BeforeCombatStart");
            }

            private static void Prefix(object[] __args)
            {
                Log("Hook.BeforeCombatStart fired. argCount=" + (__args == null ? 0 : __args.Length));
                StartCombat(__args);
            }
        }

        [HarmonyPatch]
        private static class HookAfterCombatEndPatch
        {
            private static MethodBase TargetMethod()
            {
                return AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:AfterCombatEnd");
            }

            private static void Prefix(object[] __args)
            {
                Log("Hook.AfterCombatEnd fired. argCount=" + (__args == null ? 0 : __args.Length));
                EndCombat(__args);
            }
        }

        [HarmonyPatch]
        private static class HookAfterPlayerTurnStartPatch
        {
            private static MethodBase TargetMethod()
            {
                return AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:AfterPlayerTurnStart");
            }

            private static void Prefix(object[] __args)
            {
                Log("Hook.AfterPlayerTurnStart fired. argCount=" + (__args == null ? 0 : __args.Length));
                StartPlayerTurn(__args);
            }
        }

        [HarmonyPatch]
        private static class HookAfterTurnEndPatch
        {
            private static MethodBase TargetMethod()
            {
                return AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:AfterTurnEnd");
            }

            private static void Prefix(object[] __args)
            {
                _inPlayerTurn = false;
                WriteCombatStats("turn_end");
            }
        }

        [HarmonyPatch]
        private static class HookAfterDamageGivenPatch
        {
            private static MethodBase TargetMethod()
            {
                return AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:AfterDamageGiven");
            }

            private static void Prefix(object[] __args)
            {
                Log("Hook.AfterDamageGiven fired. argCount=" + (__args == null ? 0 : __args.Length));
                AddDamageEvent(__args, "damage_given");
            }
        }

        [HarmonyPatch]
        private static class HookAfterDamageReceivedPatch
        {
            private static MethodBase TargetMethod()
            {
                return AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:AfterDamageReceived");
            }

            private static void Prefix(object[] __args)
            {
                if (IsPoisonDamage(__args) && !IsDoomDamage(__args))
                {
                    Log("Hook.AfterDamageReceived poison fired. argCount=" + (__args == null ? 0 : __args.Length));
                    AddDamageEvent(__args, "poison_damage_received");
                }
            }
        }

        [HarmonyPatch]
        private static class HookAfterDeathPatch
        {
            private static MethodBase TargetMethod()
            {
                return AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:AfterDeath");
            }

            private static void Prefix(object[] __args)
            {
                if (IsDoomDamage(__args))
                {
                    Log("Hook.AfterDeath doom fired. argCount=" + (__args == null ? 0 : __args.Length));
                    AddDamageEvent(__args, "doom_death");
                }
            }
        }

        [HarmonyPatch]
        private static class HookAfterAttackPatch
        {
            private static MethodBase TargetMethod()
            {
                return AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:AfterAttack");
            }

            private static void Prefix(object[] __args)
            {
                Log("Hook.AfterAttack fired. argCount=" + (__args == null ? 0 : __args.Length));
            }
        }

        private sealed class DamageMetrics
        {
            public int AttemptedDamage;
            public int BlockedDamage;
            public int HpDamage;

            public int TotalContribution
            {
                get { return Math.Max(AttemptedDamage, HpDamage + BlockedDamage); }
            }
        }

        private sealed class CombatDamageStats
        {
            public string PlayerId;
            public string DisplayName;
            public int TurnsTaken;
            public int CurrentTurnAttemptedDamage;
            public int CurrentTurnBlockedDamage;
            public int CurrentTurnHpDamage;
            public int CurrentTurnSpecialDamage;
            public int TotalAttemptedDamage;
            public int TotalBlockedDamage;
            public int TotalHpDamage;
            public int TotalSpecialDamage;
            public int Events;

            public int CurrentTurnContributionDamage
            {
                get { return CurrentTurnHpDamage + CurrentTurnBlockedDamage + CurrentTurnSpecialDamage; }
            }

            public int TotalContributionDamage
            {
                get { return TotalHpDamage + TotalBlockedDamage + TotalSpecialDamage; }
            }
        }

        private sealed class ReferenceEqualityComparer : IEqualityComparer<object>
        {
            public static readonly ReferenceEqualityComparer Instance = new ReferenceEqualityComparer();

            public new bool Equals(object x, object y)
            {
                return ReferenceEquals(x, y);
            }

            public int GetHashCode(object obj)
            {
                return RuntimeHelpers.GetHashCode(obj);
            }
        }
    }
}
