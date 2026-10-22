import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { AppData, AttendanceLog, SavedAccount } from '../.build/app/Contracts.js';
import { APIRequest } from '../.build/core/TronclassClient.js';

// These are offline adapter behavior tests, not an ArkTS/SDK compilation or device test.
const require = createRequire(import.meta.url);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
let ts;
try { ts = require('typescript'); }
catch {
  if (!process.env.TSC_PATH) { throw new Error('Install devDependencies or set TSC_PATH to TypeScript bin/tsc.'); }
  ts = require(path.resolve(path.dirname(fs.realpathSync(process.env.TSC_PATH)), '../lib/typescript.js'));
}

function loadAdapter(name, mocks, cache = new Map()) {
  if (cache.has(name)) { return cache.get(name); }
  const filename = path.join(root, 'entry/src/main/ets/platform', `${name}.ets`);
  const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    fileName: `${name}.ts`, compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  cache.set(name, module.exports);
  const localRequire = (specifier) => {
    if (specifier in mocks) { return mocks[specifier]; }
    if (specifier.startsWith('../')) { return require(path.join(root, '.build', `${specifier.slice(3)}.js`)); }
    if (specifier.startsWith('./')) { return loadAdapter(specifier.slice(2), mocks, cache); }
    throw new Error(`Unexpected native import: ${specifier}`);
  };
  vm.runInThisContext(`(function(require,module,exports){${output}\n})`, { filename })(localRequire, module, module.exports);
  return module.exports;
}

function nativeMocks(profile = { id: '42', user_no: 'student', name: 'Test' }) {
  const state = { metadata: new Map(), secrets: new Map(), calls: [], options: [], closed: 0,
    clearCookies: [], cookie: 'school_session=isolated', failFlush: 0, networkError: false,
    loadURL: undefined, queryAttributes: undefined, userAgent: undefined };
  const tags = { ALIAS: 1, SECRET: 2, RETURN_TYPE: 3, ACCESSIBILITY: 4, SYNC_TYPE: 5, CONFLICT_RESOLUTION: 6 };
  const alias = (attributes) => new TextDecoder().decode(attributes.get(tags.ALIAS));
  const asset = {
    Tag: tags, ReturnType: { ALL: 0 }, Accessibility: { DEVICE_UNLOCKED: 2 }, SyncType: { NEVER: 0 },
    ConflictResolution: { OVERWRITE: 0 },
    async add(attributes) {
      state.queryAttributes = new Map(attributes);
      state.secrets.set(alias(attributes), new Uint8Array(attributes.get(tags.SECRET)));
    },
    async query(attributes) {
      const secret = state.secrets.get(alias(attributes));
      if (!secret) { throw { code: 24000002 }; }
      return [new Map([[tags.SECRET, new Uint8Array(secret)]])];
    },
    async remove(attributes) {
      if (!state.secrets.delete(alias(attributes))) { throw { code: 24000002 }; }
    }
  };
  const mocks = {
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {},
    '@kit.ArkTS': { util: {
      TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } },
      TextDecoder: { create: () => ({ decodeToString: (value) => new TextDecoder().decode(value) }) }
    } },
    '@kit.ArkData': { preferences: { async getPreferences() { return {
      async get(key, fallback) { return state.metadata.get(key) ?? fallback; },
      async put(key, value) { state.metadata.set(key, value); },
      async flush() { if (state.failFlush-- > 0) { throw new Error('disk full'); } }
    }; } } },
    '@kit.AssetStoreKit': { asset },
    '@kit.RemoteCommunicationKit': { rcp: {
      Request: class { constructor(url, method, headers, content) { Object.assign(this, { url, method, headers, content }); } },
      createSession(options) {
        state.options.push(options);
        return {
          async fetch(request) {
            state.calls.push(request);
            if (state.networkError) { throw new Error('connection interrupted'); }
            return { statusCode: 200, body: new TextEncoder().encode(JSON.stringify(profile)).buffer };
          }, close() { state.closed++; }
        };
      }
    } },
    '@kit.ArkWeb': { webview: {
      WebviewController: class {
        stop() {}
        setCustomUserAgent(value) { state.userAgent = value; }
        getUserAgent() { return state.userAgent; }
        loadUrl(value) { state.loadURL?.(value); }
      },
      WebCookieManager: {
        clearAllCookiesSync(incognito) { state.clearCookies.push(incognito); },
        putAcceptThirdPartyCookieEnabled(value) { assert.equal(value, false); },
        fetchCookieSync(url, incognito) {
          assert.equal(url, 'https://lnt.xmu.edu.cn/api/profile'); assert.equal(incognito, true); return state.cookie;
        }
      }
    } }
  };
  return { state, mocks, tags };
}

test('password vault stays outside metadata, restores account/log getters, deletes idempotently', async () => {
  const { state, mocks, tags } = nativeMocks();
  const { SecureStore } = loadAdapter('SecureStore', mocks);
  const store = new SecureStore({});
  const data = new AppData();
  const account = new SavedAccount(); account.id = 'test-account'; account.username = 'student'; account.note = '备注';
  const log = new AttendanceLog(); log.username = 'student'; log.accountID = account.id;
  log.courseID = '10'; log.rollcallID = '20';
  data.accounts = [account]; data.logs = [log];
  // Accidentally attaching a field must not put it into the metadata file.
  account.password = 'should-never-be-written';
  await store.writePassword(account.id, 'secret-密码');
  await store.save(data);
  assert.equal(await store.readPassword(account.id), 'secret-密码');
  assert.equal(state.queryAttributes.get(tags.ACCESSIBILITY), 2);
  assert.equal(state.queryAttributes.get(tags.SYNC_TYPE), 0);
  assert.doesNotMatch(state.metadata.get('metadata'), /secret|password|should-never/);
  const loaded = await store.load();
  assert.equal(loaded.accounts[0].label, '备注');
  assert.equal(loaded.logs[0].resultTitle, '处理中');
  await store.deletePassword(account.id); await store.deletePassword(account.id);
  await assert.rejects(store.readPassword(account.id), /无法读取保存的密码/);
});

test('metadata flush failure restores the old preference value', async () => {
  const { state, mocks } = nativeMocks();
  const { SecureStore } = loadAdapter('SecureStore', mocks);
  const store = new SecureStore({});
  await store.save(new AppData());
  const previous = state.metadata.get('metadata');
  const changed = new AppData(); changed.accounts = [new SavedAccount()];
  state.failFlush = 1;
  await assert.rejects(store.save(changed), /本地记录保存失败/);
  assert.equal(state.metadata.get('metadata'), previous);
});

test('transport sends school-only requests, preserves course POST body and disables redirects', async () => {
  const { state, mocks } = nativeMocks();
  const { HarmonyTransport } = loadAdapter('HarmonyTransport', mocks);
  const transport = new HarmonyTransport('only=this-account');
  await transport.send(new APIRequest('/api/my-courses', 'POST', '{"page":1}'));
  assert.equal(state.calls[0].url, 'https://lnt.xmu.edu.cn/api/my-courses');
  assert.equal(state.calls[0].content, '{"page":1}');
  assert.equal(state.calls[0].headers.Cookie, 'only=this-account');
  assert.equal(state.calls[0].headers['User-Agent'], HarmonyTransport.DESKTOP_USER_AGENT);
  assert.equal(state.options[0].requestConfiguration.transfer.autoRedirect, false);
  assert.equal(state.closed, 1);
  await assert.rejects(transport.send(new APIRequest('https://other.test/api/profile')), /请求地址或方式无效/);
  assert.equal(state.calls.length, 1);
  assert.throws(() => new HarmonyTransport('x=y\r\nInjected:true'), /登录状态格式无效/);
});

test('interrupted submission stays uncertain and is sent only once', async () => {
  const { state, mocks } = nativeMocks(); state.networkError = true;
  const { HarmonyTransport } = loadAdapter('HarmonyTransport', mocks);
  await assert.rejects(new HarmonyTransport('x=y').send(new APIRequest('/api/rollcall/20/answer', 'PUT', '{}')),
    (error) => error.code === 'uncertain');
  assert.equal(state.calls.length, 1); assert.equal(state.closed, 1);
});

test('authentication can cancel before Web attaches and does not send any school request', async () => {
  const { state, mocks } = nativeMocks();
  const { WebAuthenticator } = loadAdapter('WebAuthenticator', mocks);
  const auth = new WebAuthenticator(); const account = new SavedAccount(); account.username = 'student';
  const pending = auth.authenticate(account, 'test-secret', false);
  auth.cancel();
  await assert.rejects(pending, (error) => error.code === 'cancelled');
  assert.equal(auth.active, false); assert.equal(state.calls.length, 0);
  assert.ok(state.clearCookies.every((value) => value === true));
});

test('manual authentication rejects another profile and clears incognito cookies', async () => {
  const { state, mocks } = nativeMocks({ id: '99', user_no: 'another-student', name: 'Test' });
  const { WebAuthenticator } = loadAdapter('WebAuthenticator', mocks);
  const auth = new WebAuthenticator(); const account = new SavedAccount(); account.username = 'student';
  account.verifiedStudentID = '42';
  auth.onChange = () => { if (auth.active) { auth.onControllerAttached(); } };
  state.loadURL = () => auth.onPageEnd('https://lnt.xmu.edu.cn/user/index');
  await assert.rejects(auth.authenticate(account, 'test-secret', true), (error) => error.code === 'identityMismatch');
  assert.equal(auth.active, false); assert.deepEqual(state.clearCookies, [true, true]);
  assert.equal(auth.urlLoadIntercept('https://ids.xmu.edu.cn/authserver/login'), false);
  for (const value of ['http://ids.xmu.edu.cn/', 'https://ids.xmu.edu.cn.evil.test/', 'https://ids.xmu.edu.cn@evil.test/', 'file:///etc/passwd']) {
    assert.equal(auth.urlLoadIntercept(value), true);
  }
});

test('verified manual authentication returns account-bound in-memory client', async () => {
  const { state, mocks } = nativeMocks();
  const { WebAuthenticator } = loadAdapter('WebAuthenticator', mocks);
  const auth = new WebAuthenticator(); const account = new SavedAccount(); account.username = 'student';
  auth.onChange = () => { if (auth.active) { auth.onControllerAttached(); } };
  state.loadURL = () => auth.onPageEnd('https://lnt.xmu.edu.cn/user/index');
  const session = await auth.authenticate(account, 'test-secret', true);
  assert.equal(session.accountID, account.id); assert.equal(session.profile.id, '42');
  assert.equal(auth.active, false); assert.equal(state.calls.length, 1);
  await session.client.profile();
  assert.equal(state.calls[1].headers.Cookie, state.cookie);
  assert.equal(state.calls[1].headers['User-Agent'], state.userAgent);
  assert.doesNotMatch(state.userAgent, /Mobile/i);
});
