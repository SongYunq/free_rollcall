import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { AppData, AttendanceLog, SavedAccount } from '../../.build/app/Contracts.js';

const require = createRequire(import.meta.url);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
let ts;
try { ts = require('typescript'); }
catch {
  if (!process.env.TSC_PATH) { throw new Error('Install devDependencies or set TSC_PATH to TypeScript bin/tsc.'); }
  ts = require(path.resolve(path.dirname(fs.realpathSync(process.env.TSC_PATH)), '../lib/typescript.js'));
}

// Run the actual adapter and injected page scripts; replace only the unavailable native APIs.
function loadAdapter(name, mocks, globals, cache = new Map()) {
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
    if (specifier.startsWith('./')) { return loadAdapter(specifier.slice(2), mocks, globals, cache); }
    throw new Error(`Unexpected native import: ${specifier}`);
  };
  vm.runInNewContext(`(function(require,module,exports){${output}\n})`, globals, { filename })(localRequire, module, module.exports);
  return module.exports;
}

class Element {
  constructor(id = '', tagName = 'DIV', attributes = {}) {
    this.id = id;
    this.tagName = tagName;
    this.attributes = attributes;
  }
  value = '';
  textContent = '';
  children = [];
  visible = true;
  maxLength = -1;
  disabled = false;
  events = [];
  getClientRects() { return this.visible && (!this.parentElement || this.parentElement.getClientRects().length) ? [{}] : []; }
  append(child) { child.parentElement = this; this.children.push(child); return child; }
  getAttribute(name) { return this.attributes[name] ?? null; }
  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
  querySelectorAll(selector) { return selectElements(this.children, selector); }
  focus() {}
  blur() {}
  dispatchEvent(event) { this.events.push(event.type); return true; }
  click() { this.onClick?.(); }
}

function matchesSimple(element, selector) {
  const tag = /^[a-z]+/i.exec(selector)?.[0];
  if (tag && element.tagName.toLowerCase() !== tag.toLowerCase()) { return false; }
  const id = /#([\w-]+)/.exec(selector)?.[1];
  if (id && element.id !== id) { return false; }
  const attr = /\[([\w-]+)(\*?=)["']?([^\]"']+)["']?\]/.exec(selector);
  if (attr) {
    const actual = element.getAttribute(attr[1]) ?? '';
    if (attr[2] === '=' ? actual !== attr[3] : !actual.includes(attr[3])) { return false; }
  }
  return Boolean(tag || id || attr);
}

function selectElements(roots, selector) {
  const descendants = [];
  function visit(element) { descendants.push(element); element.children.forEach(visit); }
  roots.forEach(visit);
  const alternatives = selector.split(',').map(value => value.trim().split(/\s+/));
  return descendants.filter(element => alternatives.some(parts => {
    if (!matchesSimple(element, parts[parts.length - 1])) { return false; }
    let parent = element.parentElement;
    for (let index = parts.length - 2; index >= 0; index--) {
      while (parent && !matchesSimple(parent, parts[index])) { parent = parent.parentElement; }
      if (!parent) { return false; }
      parent = parent.parentElement;
    }
    return true;
  }));
}

export class MemoryStore {
  data = new AppData();
  passwords = new Map();
  async load() { return this.clone(this.data); }
  async save(data) { this.data = this.clone(data); }
  async readPassword(id) {
    if (!this.passwords.has(id)) { throw new Error('missing credential'); }
    return this.passwords.get(id);
  }
  async writePassword(id, password) { this.passwords.set(id, password); }
  async deletePassword(id) { this.passwords.delete(id); }
  clone(source) {
    const data = new AppData();
    data.accounts = source.accounts.map(item => Object.assign(new SavedAccount(), item));
    data.logs = source.logs.map(item => Object.assign(new AttendanceLog(), item));
    return data;
  }
}

export function createAuthHarness() {
  const timers = new Map();
  let timerID = 0;
  let now = Date.parse('2026-10-22T00:00:00Z');
  const state = {
    url: 'about:blank', requests: [], controllers: [], scriptResults: [], scriptStarts: [], cookieReads: [], events: [],
    cleared: [], submitted: 0, stopped: 0, ready: false, requestFailure: undefined,
    rawScriptResults: [], profileGate: undefined, cookieDelay: 0,
    profile: { id: '42', user_no: 'student', name: '测试用户' }, nodes: new Map(), roots: [], layout: 'mobile',
    onLoad: undefined, onSubmit: undefined, onEvaluate: undefined
  };
  const globals = {
    Date: class extends Date { static now() { return now; } },
    setTimeout(callback, delay) {
      const id = ++timerID;
      const handle = setImmediate(() => {
        if (!timers.has(id)) { return; }
        timers.delete(id);
        now += delay;
        callback();
      });
      timers.set(id, handle);
      return id;
    },
    clearTimeout(id) { clearImmediate(timers.get(id)); timers.delete(id); }
  };
  const document = {
    readyState: 'complete',
    querySelector: selector => selectElements(state.roots, selector)[0] ?? null,
    getElementById: id => selectElements(state.roots, `#${id}`)[0] ?? null,
    querySelectorAll: selector => selectElements(state.roots, selector)
  };
  const mocks = {
    '@kit.ArkTS': { util: { TextDecoder: { create: () => ({
      decodeToString: value => new TextDecoder().decode(value)
    }) } } },
    '@kit.RemoteCommunicationKit': { rcp: {
      Request: class {
        constructor(url, method, headers, content) { Object.assign(this, { url, method, headers, content }); }
      },
      createSession() { return {
        async fetch(request) {
          state.requests.push(request);
          if (state.requestFailure) { throw state.requestFailure; }
          assert.equal(new URL(request.url).origin, 'https://lnt.xmu.edu.cn');
          const pathname = new URL(request.url).pathname;
          let value;
          if (pathname === '/api/profile') {
            if (state.profileGate) { await state.profileGate; }
            if (!state.ready) { return { statusCode: 401 }; }
            value = state.profile;
          } else if (pathname === '/api/current-semester-info') {
            value = { semester: { id: 1 }, academic_year: { id: 2 } };
          } else if (pathname === '/api/my-courses') {
            value = { courses: [{ id: 10, display_name: '离线回归测试课程' }], has_more: false };
          } else { throw new Error(`Unexpected offline request ${pathname}`); }
          return { statusCode: 200, body: new TextEncoder().encode(JSON.stringify(value)).buffer };
        }, close() {}
      }; }
    } },
    '@kit.ArkWeb': { webview: {
      WebviewController: class {
        constructor() { state.controllers.push(this); }
        stop() { state.stopped++; }
        getUrl() { return state.url; }
        getUserAgent() { return 'ArkWeb Offline Mobile Test'; }
        loadUrl(url) { state.url = url; state.onLoad?.(url); }
        async runJavaScript(script) {
          state.scriptStarts.push({ script, controller: this });
          await state.onEvaluate?.(script, this);
          if (state.rawScriptResults.length) { return state.rawScriptResults.shift(); }
          const location = new URL(state.url);
          const result = await vm.runInNewContext(script, {
            location, document, window: { location },
            Event: class { constructor(type) { this.type = type; } },
            HTMLInputElement: Element,
            getComputedStyle: element => ({ visibility: element.visible ? 'visible' : 'hidden', display: element.visible ? 'block' : 'none' })
          }, { timeout: 1000 });
          state.scriptResults.push(result);
          return JSON.stringify(result);
        }
      },
      WebCookieManager: {
        clearAllCookiesSync(incognito) { state.cleared.push(incognito); },
        putAcceptThirdPartyCookieEnabled(enabled) { assert.equal(enabled, false); },
        fetchCookieSync(url, incognito) {
          state.cookieReads.push({ url, incognito });
          assert.equal(incognito, true);
          if (state.cookieDelay > 0) { state.cookieDelay--; return ''; }
          return state.ready ? 'session=offline-school-session' : '';
        }
      }
    } }
  };
  const { WebAuthenticator } = loadAdapter('WebAuthenticator', mocks, globals);
  const auth = new WebAuthenticator();
  const attached = new Set();
  auth.onChange = () => {
    if (auth.active && !attached.has(auth.viewID)) {
      attached.add(auth.viewID);
      auth.onControllerAttached(auth.viewID);
    }
  };
  return {
    auth, state,
    navigate(url, { begin = true, end = false, visible = false, id = auth.viewID } = {}) {
      state.url = url;
      if (begin) { state.events.push('begin'); auth.onPageBegin(url, id); }
      if (end) { state.events.push('end'); auth.onPageEnd(url, id); }
      if (visible) { state.events.push('visible'); auth.onPageVisible?.(url, id); }
    },
    showPasswordForm({ layout = 'mobile', captcha = false, hiddenSMS = true } = {}) {
      state.nodes.clear();
      state.roots = [];
      state.layout = layout;
      let hidden;
      if (hiddenSMS) {
        hidden = new Element('phoneLoginDiv'); hidden.visible = false;
        const form = hidden.append(new Element('loginFromId', 'FORM'));
        for (const id of ['username', 'password', 'login_submit']) { form.append(new Element(id, id === 'login_submit' ? 'BUTTON' : 'INPUT')); }
        state.roots.push(hidden);
      }
      const container = new Element(layout === 'mobile' ? 'pwdLoginDiv' : 'pwdFromId', layout === 'mobile' ? 'DIV' : 'FORM');
      const form = layout === 'mobile' ? container.append(new Element('loginFromId', 'FORM')) : container;
      state.roots.push(container);
      state.nodes.set(container.id, container);
      state.nodes.set(form.id, form);
      for (const id of ['username', 'password', 'login_submit']) {
        const input = form.append(new Element(id, id === 'login_submit' ? 'BUTTON' : 'INPUT', {
          name: id === 'password' && layout === 'mobile' ? 'userPassword' : id
        }));
        state.nodes.set(id, input);
      }
      state.nodes.get('login_submit').onClick = () => { state.submitted++; state.onSubmit?.(); };
      if (captcha) { state.nodes.set('captcha', form.append(new Element('captcha', 'INPUT'))); }
      return {
        username: state.nodes.get('username'), password: state.nodes.get('password'),
        hiddenUsername: hidden?.querySelector('#username'), hiddenPassword: hidden?.querySelector('#password')
      };
    },
    showError(message) {
      const id = state.layout === 'mobile' ? 'formErrorTip2' : 'showErrorTip';
      const element = new Element(id); element.textContent = message;
      state.nodes.set(id, element);
      state.roots.at(-1).append(element);
    },
    showSliderChallenge(visible) {
      const container = new Element('sliderCaptchaDiv');
      container.visible = visible;
      container.append(new Element('slider-child'));
      state.roots.push(container);
      state.nodes.set(container.id, container);
    },
    dispose() { auth.cancel(); for (const handle of timers.values()) { clearImmediate(handle); } timers.clear(); }
  };
}

export async function settleUntil(predicate, message = 'Expected authentication transition') {
  for (let turn = 0; turn < 1000; turn++) {
    if (predicate()) { return; }
    await new Promise(resolve => setImmediate(resolve));
  }
  assert.fail(message);
}
