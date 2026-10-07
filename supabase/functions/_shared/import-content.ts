import { RequestError } from "./http.ts";

type Card = {
  fields: { Front: string; Back: string };
  card_kind: "basic";
  card_ordinal: number;
  cloze_ordinal: null;
};
export type ImportNote = {
  fields: { Front: string; Back: string };
  cards: Card[];
};
const MAX_NOTES = 10_000;
const MAX_IMPORT_BYTES = 15 * 1024 * 1024;

function note(front: string, back: string, ordinal: number): ImportNote {
  return {
    fields: { Front: front, Back: back },
    cards: [{
      fields: { Front: front, Back: back },
      card_kind: "basic",
      card_ordinal: ordinal,
      cloze_ordinal: null,
    }],
  };
}

function parseDelimited(text: string, delimiter: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let quoted = false;
  let afterQuote = false;

  const endField = () => {
    row.push(field.trim());
    field = "";
    afterQuote = false;
  };
  const endRow = () => {
    endField();
    if (row.some((cell) => cell.length > 0)) rows.push(row);
    row = [];
  };

  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (char === undefined) continue;
    if (quoted) {
      if (char === '"') {
        if (text[index + 1] === '"') {
          field += '"';
          index += 1;
        } else {
          quoted = false;
          afterQuote = true;
        }
      } else field += char;
      continue;
    }

    if (afterQuote) {
      if (char === delimiter) {
        endField();
        continue;
      }
      if (char === "\n" || char === "\r") {
        if (char === "\r" && text[index + 1] === "\n") index += 1;
        endRow();
        continue;
      }
      if (/\s/.test(char)) continue;
      throw new RequestError(
        "CSV contains characters after a closing quote",
        422,
      );
    }

    if (char === '"') {
      if (field.trim().length > 0) {
        throw new RequestError(
          "CSV contains a quote inside an unquoted field",
          422,
        );
      }
      field = "";
      quoted = true;
    } else if (char === delimiter) endField();
    else if (char === "\n" || char === "\r") {
      if (char === "\r" && text[index + 1] === "\n") index += 1;
      endRow();
    } else field += char;
  }

  if (quoted) {
    throw new RequestError("CSV contains an unterminated quoted field", 422);
  }
  if (field.length > 0 || row.length > 0 || afterQuote) endRow();
  return rows;
}

function delimitedNotes(text: string, delimiter: string): ImportNote[] {
  const rows = parseDelimited(text.replace(/^\uFEFF/, ""), delimiter);
  const hasHeader = /^front$/i.test(rows[0]?.[0] ?? "") &&
    /^back$/i.test(rows[0]?.[1] ?? "");
  const dataRows = hasHeader ? rows.slice(1) : rows;
  if (dataRows.length > MAX_NOTES) {
    throw new RequestError(`Import is limited to ${MAX_NOTES} notes`, 413);
  }
  const seen = new Set<string>();
  const result: ImportNote[] = [];
  dataRows.forEach((parts, index) => {
    const front = parts[0]?.trim() ?? "";
    const back = parts.slice(1).join(delimiter).trim();
    if (!front || !back) {
      throw new RequestError(
        `CSV row ${index + (hasHeader ? 2 : 1)} requires Front and Back`,
        422,
      );
    }
    const normalizedFront = front.normalize("NFC");
    const normalizedBack = back.normalize("NFC");
    const duplicateKey = `${normalizedFront}\u0000${normalizedBack}`;
    if (seen.has(duplicateKey)) return;
    seen.add(duplicateKey);
    result.push(note(normalizedFront, normalizedBack, result.length));
  });
  return result;
}

function markdownNotes(text: string): ImportNote[] {
  const result: ImportNote[] = [];
  let front = "";
  let back: string[] = [];
  for (const line of text.replace(/^\uFEFF/, "").split(/\r?\n/)) {
    if (/^#{1,6}\s+/.test(line)) {
      if (front && back.join(" ").trim()) {
        result.push(note(front, back.join(" "), result.length));
      }
      front = line.replace(/^#{1,6}\s+/, "").trim();
      back = [];
    } else if (/^\s*[-*]\s+/.test(line)) {
      back.push(line.replace(/^\s*[-*]\s+/, "").trim());
    } else if (line.trim()) {
      if (!front) front = line.trim();
      else back.push(line.trim());
    }
    if (result.length > MAX_NOTES) {
      throw new RequestError(`Import is limited to ${MAX_NOTES} notes`, 413);
    }
  }
  if (front && back.join(" ").trim()) {
    result.push(note(front, back.join(" "), result.length));
  }
  if (result.length > MAX_NOTES) {
    throw new RequestError(`Import is limited to ${MAX_NOTES} notes`, 413);
  }
  return result;
}

export function parseImportText(text: string, format: string): ImportNote[] {
  if (new TextEncoder().encode(text).byteLength > MAX_IMPORT_BYTES) {
    throw new RequestError("Import file exceeds 15 MiB", 413);
  }
  if (format === "csv") return delimitedNotes(text, ",");
  if (format === "quizlet") {
    const firstLine = text.split(/\r?\n/, 1)[0] ?? "";
    return delimitedNotes(text, firstLine.includes("\t") ? "\t" : ",");
  }
  if (format === "markdown" || format === "remnote") return markdownNotes(text);
  throw new RequestError("Unsupported import format", 400);
}
