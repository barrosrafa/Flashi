import sqlite3InitModule from "@sqlite.org/sqlite-wasm";
import { strFromU8, strToU8, unzipSync, zipSync } from "fflate";

const FIELD_SEPARATOR = "\u001f";
const MAX_ARCHIVE_ENTRIES = 20_000;
const MAX_MEDIA_BYTES = 50 * 1024 * 1024;

type SqlValue = string | number | bigint | Uint8Array | null;
type SqlRow = Record<string, SqlValue>;

type AnkiTemplate = {
  name?: string;
  ord?: number;
  qfmt?: string;
  afmt?: string;
};

type AnkiModel = {
  name?: string;
  flds?: Array<{ name?: string; ord?: number }>;
  tmpls?: AnkiTemplate[];
  css?: string;
};

export type ParsedAnkiCard = {
  front: string;
  back: string;
  cardKind: "basic" | "cloze";
  clozeOrdinal: number | null;
};

export type ParsedAnkiNote = {
  externalId: string;
  modelId: string;
  modifiedAt: number;
  fields: Record<string, string>;
  tags: string[];
  cards: ParsedAnkiCard[];
};

export type ParsedAnkiPackage = {
  notes: ParsedAnkiNote[];
  media: Record<string, string>;
  files: Record<string, Uint8Array>;
};

function asString(value: SqlValue | undefined): string {
  if (value === null || value === undefined) return "";
  return String(value);
}

function asNumber(value: SqlValue | undefined): number {
  const numberValue = Number(value);
  return Number.isFinite(numberValue) ? numberValue : 0;
}

function jsonObject(value: string, label: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(value) as unknown;
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      throw new Error(`${label} must be an object`);
    }
    return parsed as Record<string, unknown>;
  } catch {
    throw new Error(`Invalid ${label} JSON in Anki package`);
  }
}

function safeArchiveName(name: string): string {
  const normalized = name.replaceAll("\\", "/");
  if (!normalized || normalized.startsWith("/") || normalized.includes("../") || normalized.includes("..\\")) {
    throw new Error("Unsafe path in Anki ZIP archive");
  }
  return normalized;
}

function renderAnki(template: string, fields: Record<string, string>, frontSide = ""): string {
  let rendered = template;
  rendered = rendered.replace(/\{\{#([^}]+)\}\}([\s\S]*?)\{\{\/\1\}\}/g, (_match, field, body) =>
    fields[String(field).trim()] ? body : "");
  rendered = rendered.replace(/\{\{\^([^}]+)\}\}([\s\S]*?)\{\{\/\1\}\}/g, (_match, field, body) =>
    fields[String(field).trim()] ? "" : body);
  rendered = rendered.replace(/\{\{FrontSide\}\}/g, frontSide);
  rendered = rendered.replace(/\{\{(?:cloze|type|text):([^}]+)\}\}/g, (_match, field) => {
    const value = fields[String(field).trim()] ?? "";
    return String(value);
  });
  rendered = rendered.replace(/\{\{c(\d+)::([^}:]+)(?:::[^}]+)?\}\}/gi, "$2");
  rendered = rendered.replace(/\{\{([^}]+)\}\}/g, (_match, field) => fields[String(field).trim()] ?? "");
  return rendered;
}

function parseMediaMap(files: Record<string, Uint8Array>): Record<string, string> {
  const mediaBytes = files.media;
  if (!mediaBytes) return {};
  const raw = strFromU8(mediaBytes);
  const parsed = jsonObject(raw, "media");
  const result: Record<string, string> = {};
  for (const [key, value] of Object.entries(parsed)) {
    if (typeof value === "string") result[key] = safeArchiveName(value);
  }
  return result;
}

async function openSqlite(bytes: Uint8Array): Promise<{ sqlite3: any; db: any }> {
  const sqlite3 = await sqlite3InitModule();
  const db = new sqlite3.oo1.DB(":memory:", "c");
  const pointer = sqlite3.wasm.allocFromTypedArray(bytes);
  const flags = sqlite3.capi.SQLITE_DESERIALIZE_FREEONCLOSE |
    sqlite3.capi.SQLITE_DESERIALIZE_RESIZEABLE;
  const dbPointer = db.pointer as number | undefined;
  if (dbPointer === undefined) {
    db.close();
    throw new Error("Unable to obtain SQLite database pointer");
  }
  const result = sqlite3.capi.sqlite3_deserialize(
    dbPointer,
    "main",
    pointer,
    bytes.byteLength,
    bytes.byteLength,
    flags,
  );
  if (result !== 0) {
    db.close();
    throw new Error(`Unable to open Anki SQLite database (code ${result})`);
  }
  return { sqlite3, db };
}

function findCollection(files: Record<string, Uint8Array>): Uint8Array {
  const supported = ["collection.anki2", "collection.anki21"];
  for (const filename of supported) {
    if (files[filename]) return files[filename];
  }
  if (files["collection.anki21b"]) {
    throw new Error("collection.anki21b is not supported yet; export a legacy .apkg from Anki");
  }
  throw new Error("Anki package does not contain collection.anki2 or collection.anki21");
}

export async function parseAnkiPackage(bytes: Uint8Array): Promise<ParsedAnkiPackage> {
  if (bytes.byteLength === 0 || bytes.byteLength > MAX_MEDIA_BYTES) {
    throw new Error(`Anki package must be between 1 byte and ${MAX_MEDIA_BYTES} bytes`);
  }
  const files = unzipSync(bytes);
  const fileNames = Object.keys(files).map(safeArchiveName);
  if (fileNames.length > MAX_ARCHIVE_ENTRIES) throw new Error("Anki package has too many entries");
  const safeFiles: Record<string, Uint8Array> = {};
  for (const filename of fileNames) {
    const file = files[filename];
    if (file) safeFiles[filename] = file;
  }

  const { db } = await openSqlite(findCollection(safeFiles));
  try {
    const modelsRaw = asString(db.selectValue("select models from col limit 1"));
    const models = jsonObject(modelsRaw, "models");
    const rows = db.exec({
      sql: "select id as nid, mid, flds, tags, mod from notes order by id limit 10000",
      rowMode: "object",
      returnValue: "resultRows",
    }) as SqlRow[];
    const notes: ParsedAnkiNote[] = [];

    for (const row of rows) {
      const modelId = asString(row.mid);
      const model = (models[modelId] ?? {}) as AnkiModel;
      const modelFields = Array.isArray(model.flds) ? model.flds : [];
      const rawFields = asString(row.flds).split(FIELD_SEPARATOR);
      const fields: Record<string, string> = {};
      for (let index = 0; index < Math.max(modelFields.length, rawFields.length); index += 1) {
        const fieldName = modelFields[index]?.name?.trim() || `Field${index + 1}`;
        fields[fieldName] = rawFields[index] ?? "";
      }

      const cards: ParsedAnkiCard[] = [];
      const templates = Array.isArray(model.tmpls) ? model.tmpls : [];
      for (const template of templates) {
        const question = String(template.qfmt ?? "");
        const answer = String(template.afmt ?? "");
        if (!question && !answer) continue;
        const front = renderAnki(question, fields);
        const back = renderAnki(answer, fields, front);
        const cloze = question.match(/\{\{c(\d+)::/i);
        cards.push({
          front,
          back,
          cardKind: cloze ? "cloze" : "basic",
          clozeOrdinal: cloze ? Number(cloze[1]) : null,
        });
      }
      if (cards.length === 0) {
        const values = Object.values(fields);
        cards.push({ front: values[0] ?? "", back: values.slice(1).join("\n\n"), cardKind: "basic", clozeOrdinal: null });
      }

      notes.push({
        externalId: `anki:${asString(row.nid)}`,
        modelId,
        modifiedAt: asNumber(row.mod),
        fields,
        tags: asString(row.tags).trim().split(/\s+/).filter(Boolean).slice(0, 100),
        cards,
      });
    }
    return { notes, media: parseMediaMap(safeFiles), files: safeFiles };
  } finally {
    db.close();
  }
}

function sqlText(value: string): string {
  return value.replaceAll("\\", "\\\\");
}

function numericId(value: string, fallback: number): number {
  let hash = 2166136261;
  for (const char of value) hash = Math.imul(hash ^ char.charCodeAt(0), 16777619);
  const normalized = Math.abs(hash >>> 0);
  return normalized > 0 ? normalized : fallback;
}

export type ExportCard = {
  id: string;
  deckId: string;
  deckName: string;
  fields: Record<string, unknown>;
  tags: string[];
  media: Array<{ fieldName: string | null; filename: string; bytes: Uint8Array }>;
};

export async function buildAnkiPackage(cards: ExportCard[]): Promise<Uint8Array> {
  if (cards.length === 0) throw new Error("At least one card is required for Anki export");
  const sqlite3 = await sqlite3InitModule();
  const db = new sqlite3.oo1.DB(":memory:", "c");
  const now = Math.floor(Date.now() / 1000);
  const modelId = 1607392319;
  const deckIds = new Map<string, number>();
  for (const card of cards) {
    if (!deckIds.has(card.deckId)) deckIds.set(card.deckId, numericId(card.deckId, deckIds.size + 1));
  }
  const deckObject: Record<string, unknown> = {};
  for (const card of cards) {
    const did = deckIds.get(card.deckId) ?? 1;
    deckObject[String(did)] = {
      id: did,
      name: card.deckName.slice(0, 120),
      desc: "Exported from Flashi",
      dyn: 0,
      collapsed: false,
      conf: 1,
      extendNew: 10,
      extendRev: 50,
      mod: now,
      usn: -1,
      newToday: [now, 0],
      revToday: [now, 0],
      lrnToday: [now, 0],
    };
  }
  const model = {
    [String(modelId)]: {
      id: modelId,
      name: "Flashi Basic",
      type: 0,
      mod: now,
      usn: -1,
      sortf: 0,
      did: null,
      flds: [
        { name: "Front", ord: 0, sticky: false, rtl: false, font: "Arial", size: 20 },
        { name: "Back", ord: 1, sticky: false, rtl: false, font: "Arial", size: 20 },
      ],
      tmpls: [{ name: "Card 1", ord: 0, qfmt: "{{Front}}", afmt: "{{FrontSide}}<hr id=answer>{{Back}}", did: null, bqfmt: "", bafmt: "" }],
      css: ".card { font-family: arial; font-size: 20px; text-align: center; color: black; background-color: white; }",
      latexPre: "",
      latexPost: "",
      req: [[0, "all", [0, 1]]],
    },
  };

  db.exec(`
    pragma user_version = 11;
    create table col (id integer primary key, crt integer not null, mod integer not null, scm integer not null, ver integer not null, dty integer not null, usn integer not null, ls integer not null, conf text not null, models text not null, decks text not null, dconf text not null, tags text not null);
    create table notes (id integer primary key, guid text not null, mid integer not null, mod integer not null, usn integer not null, tags text not null, flds text not null, sfld integer not null, csum integer not null, flags integer not null, data text not null);
    create table cards (id integer primary key, nid integer not null, did integer not null, ord integer not null, mod integer not null, usn integer not null, type integer not null, queue integer not null, due integer not null, ivl integer not null, factor integer not null, reps integer not null, lapses integer not null, left integer not null, odue integer not null, odid integer not null, flags integer not null, data text not null);
    create table revlog (id integer primary key, cid integer not null, usn integer not null, ease integer not null, ivl integer not null, lastIvl integer not null, factor integer not null, time integer not null, type integer not null);
    create index ix_notes_usn on notes (usn);
    create index ix_cards_usn on cards (usn);
    create index ix_cards_nid on cards (nid);
    create index ix_revlog_usn on revlog (usn);
    create index ix_revlog_cid on revlog (cid);
  `);
  db.exec({
    sql: "insert into col values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    bind: [1, now, now, Date.now(), 11, 0, -1, 0, JSON.stringify({}), JSON.stringify(model), JSON.stringify(deckObject), JSON.stringify({}), "{}"],
  });

  const archive: Record<string, Uint8Array> = {};
  const media: Record<string, string> = {};
  const mediaByPath = new Map<string, string>();
  let mediaIndex = 0;
  let noteIndex = 0;
  for (const card of cards) {
    noteIndex += 1;
    const nid = 1_000_000_000 + noteIndex;
    const cid = nid * 10;
    const did = deckIds.get(card.deckId) ?? 1;
    const front = String(card.fields.Front ?? "");
    const back = String(card.fields.Back ?? "");
    const fields = `${front}${FIELD_SEPARATOR}${back}`;
    const tags = card.tags.map((tag) => tag.replace(/\s+/g, "_")).join(" ");
    db.exec({
      sql: "insert into notes values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      bind: [nid, `flashi-${card.id}`, modelId, now, -1, tags, fields, front, 0, 0, ""],
    });
    db.exec({
      sql: "insert into cards values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      bind: [cid, nid, did, 0, now, -1, 0, 0, noteIndex, 0, 0, 0, 0, 0, 0, 0, 0, ""],
    });

    for (const item of card.media) {
      const normalized = item.filename.replaceAll("\\", "/");
      let archiveName = mediaByPath.get(normalized);
      if (!archiveName) {
        archiveName = `${mediaIndex}`;
        mediaIndex += 1;
        mediaByPath.set(normalized, archiveName);
        media[archiveName] = normalized;
        archive[archiveName] = item.bytes;
      }
    }
  }
  db.exec({
    sql: "insert into revlog select 1, ?, -1, 3, 0, 0, 0, 0, 0 where 0",
    bind: [1],
  });
  archive["media"] = strToU8(JSON.stringify(media));
  const dbPointer = db.pointer as number | undefined;
  if (dbPointer === undefined) {
    db.close();
    throw new Error("Unable to obtain SQLite database pointer for export");
  }
  archive["collection.anki2"] = sqlite3.capi.sqlite3_js_db_export(dbPointer);
  db.close();
  return zipSync(archive, { level: 6 });
}
