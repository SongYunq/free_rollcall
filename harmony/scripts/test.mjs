import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { readdirSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
let compiler = process.env.TSC_PATH;
if (!compiler) {
  try { compiler = require.resolve('typescript/bin/tsc'); }
  catch {
    console.error('请先在 harmony/ 执行 npm install，或通过 TSC_PATH 指定已有的 TypeScript 编译器。');
    process.exit(1);
  }
}

function run(args) {
  const result = spawnSync(process.execPath, args, { cwd: root, stdio: 'inherit', env: process.env });
  if (result.error) { console.error(result.error.message); process.exit(1); }
  if (result.status !== 0) { process.exit(result.status || 1); }
}

run(['scripts/check-project.mjs']);
rmSync(new URL('../.build/', import.meta.url), { recursive: true, force: true });
run([compiler, '-p', 'tsconfig.test.json']);
const tests = readdirSync(new URL('../tests/', import.meta.url)).filter(name => name.endsWith('.test.mjs'));
run(['--test', ...tests.map(name => `tests/${name}`)]);
