// Ported from packages/api/src/common/document-bytes.ts (file-type/magic-byte validation) and
// a trimmed packages/api/src/common/image-bytes.ts (jpeg/png/webp detection only — the
// documents module's own extension map never allows heic, unlike the incident-evidence path).

export const MAX_DOCUMENT_BYTES = 10 * 1024 * 1024;

const MIME_BY_EXTENSION: Record<string, string> = {
  pdf: "application/pdf",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  png: "image/png",
  webp: "image/webp",
  txt: "text/plain",
  csv: "text/csv",
  rtf: "application/rtf",
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
};

const GENERIC_MIME = new Set(["", "application/octet-stream", "binary/octet-stream"]);
const ZIP_MIME = new Set([
  MIME_BY_EXTENSION.docx,
  MIME_BY_EXTENSION.xlsx,
  MIME_BY_EXTENSION.pptx,
]);

export class DocumentValidationError extends Error {}

export function safeDocumentFileName(value: string): string {
  const leaf = value.split(/[\\/]/).pop()?.trim() ?? "";
  // Slug so the result always satisfies is_safe_storage_deletion_path
  // ([a-zA-Z0-9_-.]+): strip accents, replace any other char (spaces, brackets,
  // unicode) with _, collapse repeats. Original name stays in documents.file_name.
  const noAccents = leaf.normalize("NFKD").replace(/[\u0300-\u036f]/g, "");
  const cleaned = noAccents
    // deno-lint-ignore no-control-regex
    .replace(/[\u0000-\u001f\u007f"<>:|?*]/g, "_")
    .replace(/[^a-zA-Z0-9_.\-]/g, "_")
    .replace(/_+/g, "_")
    .replace(/^[_.]+|[_.]+$/g, "")
    .slice(0, 180);
  if (!cleaned || cleaned === "." || cleaned === "..") {
    throw new DocumentValidationError("A valid file name is required");
  }
  return cleaned;
}

function detectImageMime(data: Uint8Array): string | null {
  if (data.length >= 3 && data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff) {
    return "image/jpeg";
  }
  if (
    data.length >= 8 &&
    data[0] === 0x89 && data[1] === 0x50 && data[2] === 0x4e && data[3] === 0x47 &&
    data[4] === 0x0d && data[5] === 0x0a && data[6] === 0x1a && data[7] === 0x0a
  ) {
    return "image/png";
  }
  if (
    data.length >= 12 &&
    asciiAt(data, 0, 4) === "RIFF" &&
    asciiAt(data, 8, 12) === "WEBP"
  ) {
    return "image/webp";
  }
  return null;
}

function asciiAt(data: Uint8Array, start: number, end: number): string {
  return String.fromCharCode(...data.subarray(start, end));
}

/** Validates claimed MIME + extension against the file's actual magic bytes. Returns the trusted MIME. */
export function assertAllowedDocumentBytes(data: Uint8Array, claimedMime: string, fileName: string): string {
  const extension = fileName.toLowerCase().match(/\.([a-z0-9]+)$/)?.[1] ?? "";
  const trustedMime = MIME_BY_EXTENSION[extension];
  if (!trustedMime) {
    throw new DocumentValidationError(
      "Unsupported file type. Use PDF, modern Office, image, text, CSV, or RTF files.",
    );
  }

  const normalizedClaim = claimedMime.toLowerCase().trim();
  if (!GENERIC_MIME.has(normalizedClaim) && normalizedClaim !== trustedMime) {
    throw new DocumentValidationError("File content type does not match its extension");
  }

  if (trustedMime.startsWith("image/")) {
    if (detectImageMime(data) !== trustedMime) {
      throw new DocumentValidationError("Image content does not match its extension");
    }
  } else if (trustedMime === MIME_BY_EXTENSION.pdf) {
    if (asciiAt(data, 0, 5) !== "%PDF-") throw new DocumentValidationError("Invalid PDF file");
  } else if (ZIP_MIME.has(trustedMime)) {
    const sig = Array.from(data.subarray(0, 4)).map((b) => b.toString(16).padStart(2, "0")).join("");
    if (!["504b0304", "504b0506", "504b0708"].includes(sig)) {
      throw new DocumentValidationError("Invalid Office document");
    }
  } else if (trustedMime === MIME_BY_EXTENSION.rtf) {
    if (!asciiAt(data, 0, 5).startsWith("{\\rtf")) throw new DocumentValidationError("Invalid RTF file");
  } else if (data.includes(0)) {
    throw new DocumentValidationError("Text documents cannot contain binary data");
  }

  return trustedMime;
}
