import { describe, expect, it } from 'vitest';
import { csvCell, csvDocument } from './csv';

describe('csvCell', () => {
  it('quotes plain strings', () => {
    expect(csvCell('hello')).toBe('"hello"');
  });

  it('escapes embedded double quotes', () => {
    expect(csvCell('a "b" c')).toBe('"a ""b"" c"');
  });

  it('neutralizes formula-injection prefixes', () => {
    expect(csvCell('=1+1')).toBe(`"'=1+1"`);
    expect(csvCell('+44 7700')).toBe(`"'+44 7700"`);
    expect(csvCell('-2')).toBe(`"'-2"`);
    expect(csvCell('@SUM(A1)')).toBe(`"'@SUM(A1)"`);
  });

  it('neutralizes a formula prefix hidden behind leading whitespace', () => {
    // Several spreadsheet apps trim leading whitespace before deciding
    // whether a cell is a formula, so " =1+1" is still dangerous.
    expect(csvCell(' =1+1')).toBe(`"' =1+1"`);
    expect(csvCell('\t@SUM(A1)')).toBe(`"'\t@SUM(A1)"`);
  });

  it('does not prefix numbers', () => {
    expect(csvCell(-2)).toBe('"-2"');
    expect(csvCell(0)).toBe('"0"');
  });

  it('renders null/undefined as an empty cell', () => {
    expect(csvCell(null)).toBe('""');
    expect(csvCell(undefined)).toBe('""');
  });
});

describe('csvDocument', () => {
  it('prefixes the UTF-8 BOM so Excel on Windows decodes as UTF-8', () => {
    // Without it, "Renée Söderberg" arrives as "RenÃ©e SÃ¶derberg" on a payroll
    // export, because Excel ignores the charset content-type parameter.
    const doc = csvDocument(['Employee', '"Renée Söderberg"']);
    expect(doc.charCodeAt(0)).toBe(0xfeff);
    expect(Buffer.from(doc, 'utf8').subarray(0, 3)).toEqual(Buffer.from([0xef, 0xbb, 0xbf]));
  });

  it('separates rows with CRLF per RFC 4180 and ends with one', () => {
    expect(csvDocument(['a', 'b'])).toBe('\ufeffa\r\nb\r\n');
  });

  it('round-trips non-ASCII names through UTF-8 intact', () => {
    const doc = csvDocument([csvCell('Renée Söderberg')]);
    const decoded = Buffer.from(doc, 'utf8').toString('utf8');
    expect(decoded).toContain('Renée Söderberg');
  });

  it('handles a single-row document', () => {
    expect(csvDocument(['only'])).toBe('\ufeffonly\r\n');
  });
});
