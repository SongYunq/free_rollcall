import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = path => readFileSync(join(root, path), 'utf8');
const config = path => JSON.parse(read(path));
const profile = config('build-profile.json5');
assert.equal(profile.app.products[0].compatibleSdkVersion, '5.0.0(12)');
assert.equal(profile.app.products[0].runtimeOS, 'HarmonyOS');
assert(profile.app.signingConfigs === undefined || Array.isArray(profile.app.signingConfigs), '签名配置应为数组');
const module = config('entry/src/main/module.json5').module;
assert.deepEqual(module.requestPermissions.map(value => value.name), ['ohos.permission.INTERNET']);
assert(existsSync(join(root, 'entry/src/main', module.abilities[0].srcEntry)));
for (const page of config('entry/src/main/resources/base/profile/main_pages.json').src) {
  assert(existsSync(join(root, `entry/src/main/ets/${page}.ets`)), `Missing page: ${page}`);
}

function files(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? files(path) : [path];
  });
}

const sourceFiles = files(join(root, 'entry/src/main/ets'));
const resources = new Map();
for (const scope of ['AppScope', 'entry/src/main']) {
  const base = join(root, scope, 'resources/base');
  for (const file of files(base)) {
    const extension = extname(file);
    if (file.includes('/media/')) { resources.set(`media.${file.split('/').at(-1).slice(0, -extension.length)}`, file); }
    if (extension === '.json' && file.includes('/element/')) {
      const data = JSON.parse(readFileSync(file, 'utf8'));
      for (const [kind, entries] of Object.entries(data)) {
        for (const entry of entries) { resources.set(`${kind}.${entry.name}`, file); }
      }
    }
  }
}
for (const file of sourceFiles) {
  const source = readFileSync(file, 'utf8');
  for (const match of source.matchAll(/from\s+['"](\.[^'"]+)['"]/g)) {
    const candidate = resolve(dirname(file), match[1]);
    assert(['.ts', '.ets', '.js'].some(extension => existsSync(candidate + extension)), `Missing import ${match[1]} in ${file}`);
  }
  for (const match of source.matchAll(/\$r\(['"]app\.([^'"]+)['"]\)/g)) {
    assert(resources.has(match[1]), `Missing resource ${match[1]} in ${file}`);
  }
}
for (const file of ['AppScope/app.json5', 'entry/src/main/module.json5', 'entry/build-profile.json5',
  'oh-package.json5', 'entry/oh-package.json5', 'hvigor/hvigor-config.json5']) { config(file); }
console.log(`工程结构、相对导入、资源引用和最低系统配置检查通过（${sourceFiles.length} 个源码文件）。`);
console.log('此检查不替代 DevEco Studio 的 ArkTS 编译、原生界面及设备验证。');
