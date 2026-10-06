/**
 * Paths whose declared payload capacity exceeds the 1 MB default.
 *
 * The POS and reservation ingest routes accept up to 1000 rows each
 * (`@ArrayMaxSize(MAX_INGEST_ROWS)`), which at a realistic ~816 bytes per check
 * plus ~320 per labor punch is ~1.08 MB — so a delivery at the advertised
 * maximum was rejected by Express with a 413 before Nest ever saw it, silently
 * dropping a busy night's sales. Both are authenticated by a per-connection
 * webhook secret before any work happens, so this does not widen the
 * unauthenticated surface.
 */
const LARGE_JSON_BODY_PATHS = [
  /^\/api\/v1\/chat\/images$/,
  /^\/api\/v1\/bar-inventory\/parse$/,
  /^\/api\/v1\/operations\/checklist\/complete\/[^/]+$/,
  /^\/api\/v1\/documents$/,
  /^\/api\/v1\/pos\/ingest\/[^/]+$/,
  /^\/api\/v1\/reservations\/ingest\/[^/]+$/,
  // Profile-photo routes accept up to 5 MB of decoded image bytes
  // (UploadProfilePhotoDto.dataBase64, app-profile.controller.ts), which base64-encoded is
  // ~6.7 MB of JSON — well past the 1 MB default, so a normal phone photo was rejected by
  // Express before the controller ever ran.
  /^\/api\/v1\/app\/me\/photo$/,
  /^\/api\/v1\/app\/staff\/[^/]+\/photo$/,
];

export function jsonBodyLimitForPath(path: string, largeBodyLimit: string): string {
  return LARGE_JSON_BODY_PATHS.some((pattern) => pattern.test(path)) ? largeBodyLimit : '1mb';
}
