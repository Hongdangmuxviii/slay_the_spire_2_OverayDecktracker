const fs = require("fs");
const path = require("path");

const rewardFile = path.join(
  __dirname,
  "..",
  "mods",
  "RewardBridgeExport.current.json"
);
const aliasFile = path.join(
  __dirname,
  "data",
  "necrobinder_card_aliases.json"
);
const appDataDir = process.env.APPDATA
  ? path.join(process.env.APPDATA, "SlayTheSpire2")
  : null;

let lastPayload = "";
let lastStatus = "";
let lastSavePath = "";
let aliasIndex = null;

function renderStatus(lines) {
  const text = lines.join("\n");
  if (text === lastStatus) {
    return;
  }

  lastStatus = text;
  console.clear();
  console.log(text);
}

function walk(dir, results) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(fullPath, results);
      continue;
    }

    if (/^current_run(_mp)?\.save$/i.test(entry.name)) {
      const stat = fs.statSync(fullPath);
      results.push({ fullPath, mtimeMs: stat.mtimeMs });
    }
  }
}

function normalizeAlias(text) {
  return String(text || "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, " ");
}

function loadAliasIndex() {
  if (aliasIndex) {
    return aliasIndex;
  }

  const index = {
    byId: new Map(),
    byAlias: new Map()
  };

  try {
    const payload = fs.readFileSync(aliasFile, "utf8").replace(/^\uFEFF/, "");
    const entries = JSON.parse(payload);
    for (const entry of Array.isArray(entries) ? entries : []) {
      if (!entry || !entry.id) {
        continue;
      }

      index.byId.set(entry.id, entry);
      const aliases = Array.isArray(entry.aliases) ? entry.aliases : [];
      for (const alias of aliases) {
        const key = normalizeAlias(alias);
        if (key) {
          index.byAlias.set(key, entry.id);
        }
      }
    }
  } catch (error) {
    // Keep going without aliases if the file is missing or invalid.
  }

  aliasIndex = index;
  return aliasIndex;
}

function resolveCardEntry(input) {
  const index = loadAliasIndex();
  const text = String(input || "").trim();
  if (!text) {
    return null;
  }

  if (index.byId.has(text)) {
    return index.byId.get(text);
  }

  const mappedId = index.byAlias.get(normalizeAlias(text));
  if (mappedId && index.byId.has(mappedId)) {
    return index.byId.get(mappedId);
  }

  return null;
}

function formatCardLabel(input) {
  const entry = resolveCardEntry(input);
  if (!entry) {
    return String(input || "");
  }

  return `${entry.id} | ${entry.name_ko} | ${entry.name_en}`;
}

function findLatestRunSave() {
  if (!appDataDir || !fs.existsSync(appDataDir)) {
    return null;
  }

  const candidates = [];
  walk(appDataDir, candidates);
  if (candidates.length === 0) {
    return null;
  }

  const singlePlayerCandidates = candidates.filter(candidate =>
    /current_run\.save$/i.test(candidate.fullPath)
  );
  if (singlePlayerCandidates.length > 0) {
    singlePlayerCandidates.sort((a, b) => b.mtimeMs - a.mtimeMs);
    return singlePlayerCandidates[0].fullPath;
  }

  candidates.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return candidates[0].fullPath;
}

function parseRunSave() {
  try {
    const savePath = findLatestRunSave();
    if (!savePath) {
      return {
        savePath: "",
        deckIds: [],
        relicIds: [],
        characterId: "",
        currentHp: "",
        currentGold: ""
      };
    }

    lastSavePath = savePath;
    const payload = fs.readFileSync(savePath, "utf8").replace(/^\uFEFF/, "");
    const parsed = JSON.parse(payload);
    const players = Array.isArray(parsed.players) ? parsed.players : [];
    const player = players[0] || {};
    const deck = Array.isArray(player.deck) ? player.deck : [];
    const relics = Array.isArray(player.relics) ? player.relics : [];

    return {
      savePath,
      deckIds: deck.map(card => card && card.id).filter(Boolean),
      relicIds: relics.map(relic => relic && relic.id).filter(Boolean),
      characterId: player.character_id || "",
      currentHp: player.current_hp ?? "",
      currentGold: player.gold ?? player.current_gold ?? ""
    };
  } catch (error) {
    return {
      savePath: lastSavePath,
      deckIds: [],
      relicIds: [],
      characterId: "",
      currentHp: "",
      currentGold: "",
      error: error.message
    };
  }
}

function readRewardFile() {
  try {
    const payload = fs.readFileSync(rewardFile, "utf8").replace(/^\uFEFF/, "");
    lastPayload = payload;
    const parsed = JSON.parse(payload);
    const cards = Array.isArray(parsed.card_ids) ? parsed.card_ids : [];
    const run = parseRunSave();

    const lines = [];
    lines.push("RewardBridgeExport");
    lines.push("status: watching");
    lines.push("updated_at: " + (parsed.updated_at || ""));
    lines.push("reason: " + (parsed.reason || ""));
    lines.push("count: " + (parsed.count || 0));
    lines.push("cards:");
    for (const cardId of cards) {
      lines.push(" - " + formatCardLabel(cardId));
    }
    if (cards.length === 0) {
      lines.push(" - (none yet)");
    }
    lines.push("");
    lines.push("run:");
    lines.push(" character: " + (run.characterId || "(unknown)"));
    lines.push(" hp: " + (run.currentHp === "" ? "(unknown)" : run.currentHp));
    lines.push(" gold: " + (run.currentGold === "" ? "(unknown)" : run.currentGold));
    lines.push(" deck_count: " + run.deckIds.length);
    lines.push(" save_name: " + (run.savePath ? path.basename(run.savePath) : "(not found)"));
    if (run.error) {
      lines.push(" save_error: " + run.error);
    } else {
      lines.push(" save_path: " + (run.savePath || "(not found)"));
    }
    lines.push("deck:");
    for (const deckId of run.deckIds) {
      lines.push(" - " + formatCardLabel(deckId));
    }
    if (run.deckIds.length === 0) {
      lines.push(" - (none yet)");
    }
    lines.push("relics:");
    for (const relicId of run.relicIds) {
      lines.push(" - " + relicId);
    }
    if (run.relicIds.length === 0) {
      lines.push(" - (none yet)");
    }

    renderStatus(lines);
  } catch (error) {
    if (error.code === "ENOENT") {
      renderStatus([
        "RewardBridgeExport",
        "status: waiting for RewardBridgeExport.current.json",
        "path: " + rewardFile
      ]);
      return;
    }

    renderStatus([
      "RewardBridgeExport",
      "status: waiting",
      "note: reward file is being updated or invalid right now",
      "error: " + error.message
    ]);
  }
}

setInterval(readRewardFile, 500);
readRewardFile();
