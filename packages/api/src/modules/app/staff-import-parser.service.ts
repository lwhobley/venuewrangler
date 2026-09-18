import { BadRequestException, Injectable } from '@nestjs/common';
import { callAiJson, resolveAiApiKey, resolveAiModel } from '../../common/ai-json-parse';

const MAX_IMPORT_ROWS = 200;
const MAX_TEXT_CHARS = 40_000;
const DEFAULT_MODEL = 'gemini-flash-latest';

const PROMPT =
  'Extract a staff roster from this export. It may come from Homebase, When I Work, ' +
  '7shifts, Deputy, Sling, a spreadsheet, or a plain pasted list — the exact source is ' +
  'unknown, so infer columns from context rather than expecting fixed headers. For each ' +
  'person return their full name, email if present, phone if present, and their job ' +
  'title/position and hourly wage if present. Guess an access role: "manager" for anyone titled manager, ' +
  'supervisor, GM, or owner; "staff" for everyone else. Skip rows that are clearly not ' +
  'people (headers, totals, blank rows). Return STRICT JSON matching schema: ' +
  '{"items": [{"fullName": "string", "email": "string", "phone": "string", "jobTitle": "string", "hourlyRateCents": 0, "role": "manager"|"staff"}]}';

export type ParsedStaffRow = {
  fullName: string;
  email: string;
  phone?: string;
  jobTitle: string;
  role: 'manager' | 'staff';
  hourlyRateCents?: number;
};

export type ParsedStaffResult = {
  items: ParsedStaffRow[];
};

@Injectable()
export class StaffImportParserService {
  async parse(text: string): Promise<ParsedStaffResult> {
    const trimmed = text?.trim() ?? '';
    if (!trimmed) {
      throw new BadRequestException('Paste a staff list or CSV export to parse');
    }
    if (trimmed.length > MAX_TEXT_CHARS) {
      throw new BadRequestException(`Staff imports are limited to ${MAX_TEXT_CHARS.toLocaleString()} characters`);
    }
    const apiKey = resolveAiApiKey();
    if (!apiKey) throw new BadRequestException('AI parsing requires GEMINI_API_KEY configuration');

    const parsed = await callAiJson({
      apiKey,
      model: resolveAiModel(process.env.GEMINI_STAFF_IMPORT_MODEL, DEFAULT_MODEL),
      prompt: PROMPT,
      userText: trimmed,
    });

    return this.normalize(parsed);
  }

  normalize(parsed: unknown): ParsedStaffResult {
    if (!parsed || typeof parsed !== 'object' || !Array.isArray((parsed as { items?: unknown }).items)) {
      throw new BadRequestException('AI staff parser returned invalid JSON. Try again with clearer input.');
    }

    const raw = parsed as { items: unknown[] };
    const items = raw.items
      .slice(0, MAX_IMPORT_ROWS)
      .map((item): ParsedStaffRow | null => {
        const row = item && typeof item === 'object' ? (item as Record<string, unknown>) : {};
        const email = cleanText(row.email);
        const fullName = cleanText(row.fullName);
        if (!email || !fullName) return null;
        return {
          fullName,
          email: email.toLowerCase(),
          phone: cleanText(row.phone),
          jobTitle: cleanText(row.jobTitle) ?? 'Team Member',
          role: row.role === 'manager' ? 'manager' : 'staff',
          hourlyRateCents: typeof row.hourlyRateCents === 'number' && Number.isFinite(row.hourlyRateCents) ? Math.round(row.hourlyRateCents * 100) : undefined,
        };
      })
      .filter((row): row is ParsedStaffRow => row !== null);

    return { items };
  }
}

function cleanText(value: unknown): string | undefined {
  const trimmed = typeof value === 'string' ? value.trim() : '';
  return trimmed ? trimmed : undefined;
}
