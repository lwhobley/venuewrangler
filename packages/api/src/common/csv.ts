/**
 * Quotes a CSV cell and neutralizes spreadsheet formula injection: string
 * values starting with =, +, -, @, tab or CR are prefixed with a single quote
 * so Excel/Sheets treat them as text. Numbers pass through unprefixed.
 */
/**
 * Assemble CSV rows into a downloadable document.
 *
 * Excel on Windows ignores the `charset=utf-8` content-type parameter for a
 * downloaded file and decodes as the system ANSI codepage, so "Renée Söderberg"
 * arrives as "RenÃ©e SÃ¶derberg" on a payroll export. A UTF-8 BOM is what makes
 * it decode correctly. RFC 4180 also specifies CRLF row endings.
 */
export function csvDocument(rows: string[]): string {
  return `﻿${rows.join('\r\n')}\r\n`;
}

export function csvCell(value: string | number | null | undefined): string {
  if (value == null) return '""';
  let text = String(value);
  // Leading whitespace doesn't stop a spreadsheet app from treating the
  // cell as a formula -- several trim before deciding, so check past it too.
  if (typeof value === 'string' && /^[\s]*[=+\-@\t\r]/.test(text)) {
    text = `'${text}`;
  }
  return `"${text.replace(/"/g, '""')}"`;
}
