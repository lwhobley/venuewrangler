import { safeDocumentFileName } from "./document-bytes.ts";

Deno.test("non-Latin document names retain a supported extension", () => {
  const name = safeDocumentFileName("Меню.pdf");
  if (name !== "document.pdf") throw new Error(`Unexpected file name: ${name}`);
});

Deno.test("document object keys cannot contain doubled dots", () => {
  const name = safeDocumentFileName("report..final.pdf");
  if (name.includes("..") || !name.endsWith(".pdf")) {
    throw new Error(`Unsafe file name: ${name}`);
  }
});
