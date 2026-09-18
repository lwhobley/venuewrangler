import { createRequire } from 'node:module';
import { describe, expect, it } from 'vitest';

const nodeRequire = createRequire(import.meta.url);
const { getAssetSize, isAssetTypeAnImage } = nodeRequire('metro/private/Assets') as {
  getAssetSize(type: string, input: Buffer, filePath: string): unknown;
  isAssetTypeAnImage(type: string): boolean;
};

// Metro 0.84 excludes these formats and no longer uses image-size.
describe('Metro image parser hardening', () => {
  it.each(['icns', 'heif', 'jxl'])('does not parse unsupported %s assets', (type) => {
    expect(isAssetTypeAnImage(type)).toBe(false);
    expect(getAssetSize(type, Buffer.from('malformed'), `asset.${type}`)).toBeNull();
  });
});
