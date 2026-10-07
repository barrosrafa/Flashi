import { parseImportText } from "./import-content.ts";

function equal(actual: unknown, expected: unknown, message: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `${message}: got ${JSON.stringify(actual)}, expected ${
        JSON.stringify(expected)
      }`,
    );
  }
}
function throws(run: () => unknown, fragment: string): void {
  try {
    run();
  } catch (error) {
    if (error instanceof Error && error.message.includes(fragment)) return;
    throw error;
  }
  throw new Error(`Expected an error containing: ${fragment}`);
}

Deno.test("F11 CSV handles BOM, accents, quoted commas, escaped quotes, multiline and duplicates", () => {
  const notes = parseImportText(
    '\uFEFFFront,Back\r\n"Capital, Brazil","Brasília, a capital"\r\n"He said ""hi""","A quote"\r\n"Capital, Brazil","Brasília, a capital"\r\n"Linha 1","Linha 2\ncom acentos: ação"',
    "csv",
  );
  equal(notes.map((item) => item.fields), [
    { Front: "Capital, Brazil", Back: "Brasília, a capital" },
    { Front: 'He said "hi"', Back: "A quote" },
    { Front: "Linha 1", Back: "Linha 2\ncom acentos: ação" },
  ], "CSV values");
});

Deno.test("Quizlet accepts tab-separated UTF-8 rows", () => {
  const notes = parseImportText("pergunta\tresposta\nmaçã\tfruta", "quizlet");
  equal(notes.map((item) => item.fields), [{
    Front: "pergunta",
    Back: "resposta",
  }, { Front: "maçã", Back: "fruta" }], "Quizlet rows");
});

Deno.test("F11 CSV rejects malformed quoting, missing values, invalid format and oversized text", () => {
  throws(
    () => parseImportText('front,back\n"oops,answer', "csv"),
    "unterminated quoted field",
  );
  throws(
    () => parseImportText("front,back\nquestion,", "csv"),
    "requires Front and Back",
  );
  throws(() => parseImportText("front,back\nquestion,answer", "tsv"), "Unsupported import format");
  throws(() => parseImportText("x".repeat(15 * 1024 * 1024 + 1), "csv"), "exceeds 15 MiB");
});
