import { FileBlob, SpreadsheetFile } from "@oai/artifact-tool";

const paths = process.argv.slice(2);
if (paths.length === 0) {
  throw new Error("Pass one or more TbLanguage.xlsx paths.");
}

for (const path of paths) {
  const input = await FileBlob.load(path);
  const workbook = await SpreadsheetFile.importXlsx(input);
  const report = await workbook.inspect({
    kind: "workbook,sheet,table",
    maxChars: 6000,
    tableMaxRows: 5,
    tableMaxCols: 18,
    tableMaxCellChars: 60,
  });
  console.log(`\n=== ${path} ===\n${report.ndjson}`);
}
