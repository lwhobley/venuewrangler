import { createHash } from 'node:crypto';
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

// Build inputs only: never environment files, dependencies or generated output.
export function sourceManifest(root = process.cwd()) {
  const files = ['package.json', 'package-lock.json', 'Dockerfile', '.dockerignore',
    'scripts/api-source-manifest.mjs', 'packages/api/package.json',
    'packages/api/nest-cli.json', 'packages/api/tsconfig.json',
    'packages/api/tsconfig.build.json', 'packages/api/prisma.config.ts'];
  function walk(directory) {
    for (const entry of readdirSync(resolve(root, directory), { withFileTypes: true })) {
      if (entry.name.startsWith('.') || ['node_modules', 'dist'].includes(entry.name)) continue;
      const path = `${directory}/${entry.name}`;
      if (entry.isDirectory()) walk(path);
      else if (entry.isFile() && /\.(ts|mts|mjs|json|sql|prisma|toml)$/.test(entry.name)) files.push(path);
    }
  }
  for (const dir of ['packages/api/src', 'packages/api/prisma', 'packages/api/scripts']) walk(dir);
  return { version: 1, files: Object.fromEntries(files.sort().map((file) => [file,
    createHash('sha256').update(readFileSync(resolve(root, file), 'utf8').replace(/\r\n/g, '\n')).digest('hex'),
  ])) };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const current = sourceManifest();
  if (process.argv[2] === '--compare') {
    const deployed = JSON.parse(readFileSync(process.argv[3], 'utf8'));
    if (deployed.version !== 1 || !deployed.files || typeof deployed.files !== 'object') throw new Error('Missing or unsupported image source manifest');
    const paths = new Set([...Object.keys(current.files), ...Object.keys(deployed.files)]);
    const changed = [...paths].filter((file) => current.files[file] !== deployed.files[file]);
    if (changed.length) {
      console.error(`Production image differs from main in ${changed.length} API build input(s).`);
      process.exitCode = 1;
    } else console.log('Serving image API build inputs match main.');
  } else if (process.argv[2] === '--output' && process.argv[3]) {
    writeFileSync(process.argv[3], JSON.stringify(current));
  } else throw new Error('Use --output <manifest> or --compare <manifest>');
}
