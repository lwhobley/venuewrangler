import { basename, join } from 'node:path';

export function shouldCopySiteSource(source, root) {
  return source !== join(root, 'site', 'app') && !/\.(spec|test)\.[cm]?[jt]sx?$/.test(basename(source));
}
