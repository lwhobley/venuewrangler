import { describe, expect, it } from 'vitest';
import { sourceManifest } from './api-source-manifest.mjs';

describe('API build-input manifest', () => {
  it('includes lockfile, container and API inputs without reading environment snapshots', () => {
    const manifest = sourceManifest();
    expect(manifest.version).toBe(1);
    expect(manifest.files['package-lock.json']).toMatch(/^[a-f0-9]{64}$/);
    expect(manifest.files.Dockerfile).toMatch(/^[a-f0-9]{64}$/);
    expect(manifest.files['packages/api/src/main.ts']).toMatch(/^[a-f0-9]{64}$/);
    expect(Object.keys(manifest.files).some((path) => /(^|\/)\.env/.test(path))).toBe(false);
    expect(Object.keys(manifest.files).some((path) => path.includes('node_modules'))).toBe(false);
    expect(sourceManifest()).toEqual(manifest);
  });
});
