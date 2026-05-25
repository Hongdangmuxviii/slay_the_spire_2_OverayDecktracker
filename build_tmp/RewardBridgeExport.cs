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
        private static string _logPath;

        public static void Initialize()
        {
            var modDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location) ?? AppContext.BaseDirectory;
            _outputPath = Path.Combine(modDir, "RewardBridgeExport.current.json");
            _logPath = Path.Combine(modDir, "RewardBridgeExport.log");

            Log("Patch target screen_ready=" + SafeMethodName(AccessTools.Method("MegaCrit.Sts2.Core.Nodes.Screens.CardSelection.NCardRewardSelectionScreen:_Ready")));
            Log("Patch target screen_exit=" + SafeMethodName(AccessTools.Method("MegaCrit.Sts2.Core.Nodes.Screens.CardSelection.NCardRewardSelectionScreen:_ExitTree")));
            Log("Patch target button_ready=" + SafeMethodName(AccessTools.Method("MegaCrit.Sts2.Core.Nodes.Screens.CardSelection.NCardRewardAlternativeButton:_Ready")));
            Log("Patch target hook_after_modify=" + SafeMethodName(AccessTools.Method("MegaCrit.Sts2.Core.Hooks.Hook:AfterModifyingCardRewardOptions")));

            var harmony = new Harmony("RewardBridgeExport");
            harmony.PatchAll(Assembly.GetExecutingAssembly());
            Log("Initialized.");
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
