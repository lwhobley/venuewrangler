import { basename, join } from 'node:path';

// Internal files that must not be published: test specs, JSX sources compiled to a sibling
// .js (e.g. opener.src.jsx), and markdown notes such as NEEDS_REAL_FINGERPRINT.md.
const INTERNAL_FILE = /(\.(spec|test)\.[cm]?[jt]sx?|\.src\.[^/]+|NEEDS_REAL_FINGERPRINT[^/]*|\.md)$/;

export function shouldCopySiteSource(source, root) {
  return source !== join(root, 'site', 'app') && !INTERNAL_FILE.test(basename(source));
}
