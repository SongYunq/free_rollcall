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
  remove() {
    if (this.parentElement) { this.parentElement.children = this.parentElement.children.filter(child => child !== this); }
    this.parentElement = undefined;
  }
  getAttribute(name) { return this.attributes[name] ?? null; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
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
    userAgentChanges: [], loads: [], transitions: [], loginModeSwitches: [], cookie: 'session=offline-school-session',
    cleared: [], submitted: 0, clicks: 0, stopped: 0, ready: false, requestFailure: undefined,
    rawScriptResults: [], profileGate: undefined, cookieDelay: 0,
    profile: { id: '42', user_no: 'student', name: '测试用户' }, nodes: new Map(), roots: [], layout: 'mobile',
    onLoad: undefined, onSubmit: undefined, onEvaluate: undefined, onScriptResult: undefined, onCheckForm: undefined,
    onLoginModeSwitch: undefined,
    bindSubmitHandler: true, pageWindow: {}
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
        userAgent = 'ArkWeb Offline Mobile Test';
        constructor() { state.controllers.push(this); }
        stop() { state.stopped++; }
        getUrl() { return state.url; }
        getUserAgent() { return this.userAgent; }
        setCustomUserAgent(value) {
          this.userAgent = value;
          state.userAgentChanges.push({ controller: this, value });
          state.events.push('user-agent');
        }
        loadUrl(url) {
          state.loads.push({ url, userAgent: this.userAgent, controller: this, cleared: state.cleared.length });
          state.events.push('load');
          state.url = url;
          state.onLoad?.(url);
        }
        async runJavaScript(script) {
          state.scriptStarts.push({ script, controller: this });
          await state.onEvaluate?.(script, this);
          if (state.rawScriptResults.length) { return state.rawScriptResults.shift(); }
          const location = new URL(state.url);
          const result = await vm.runInNewContext(script, {
            ...state.pageWindow, location, document, window: { ...state.pageWindow, location },
            Event: class { constructor(type) { this.type = type; } },
            HTMLInputElement: Element,
            getComputedStyle: element => ({ visibility: element.visible ? 'visible' : 'hidden', display: element.visible ? 'block' : 'none' })
          }, { timeout: 1000 });
          state.scriptResults.push(result);
          return state.onScriptResult ? state.onScriptResult(result, script) : JSON.stringify(result);
        }
      },
      WebCookieManager: {
        clearAllCookiesSync(incognito) {
          state.cleared.push(incognito);
          state.events.push('clear-cookies');
          state.ready = false;
        },
        putAcceptThirdPartyCookieEnabled(enabled) { assert.equal(enabled, false); },
        fetchCookieSync(url, incognito) {
          state.cookieReads.push({ url, incognito });
          assert.equal(incognito, true);
          if (state.cookieDelay > 0) { state.cookieDelay--; return ''; }
          return state.ready ? state.cookie : '';
        }
      }
    } }
  };
  const { WebAuthenticator } = loadAdapter('WebAuthenticator', mocks, globals);
  const auth = new WebAuthenticator();
  const attached = new Set();
  auth.onChange = () => {
    state.transitions.push({ active: auth.active, manual: auth.manual, progress: auth.progress, time: now });
    if (auth.active && !attached.has(auth.viewID)) {
      attached.add(auth.viewID);
      auth.onControllerAttached(auth.viewID);
    }
  };
  return {
    auth, state, document,
    elapsed: () => now - Date.parse('2026-10-22T00:00:00Z'),
    navigate(url, { begin = true, end = false, visible = false, id = auth.viewID } = {}) {
      state.url = url;
      if (begin) { state.events.push('begin'); auth.onPageBegin(url, id); }
      if (end) { state.events.push('end'); auth.onPageEnd(url, id); }
      if (visible) { state.events.push('visible'); auth.onPageVisible?.(url, id); }
    },
    showAccountLoginLink({ href = '/authserver/login?type=userNameLogin', visible = true } = {}) {
      state.nodes.clear();
      state.roots = [];
      state.pageWindow = {};
      const link = new Element('account-login-link', 'A', { href });
      link.visible = visible;
      link.onClick = () => {
        state.loginModeSwitches.push(href);
        state.onLoginModeSwitch?.(href);
      };
      state.roots.push(link);
      state.nodes.set(link.id, link);
      return link;
    },
    showPasswordForm({ layout = 'mobile', captcha = false, hiddenSMS = true, hiddenLoginMode } = {}) {
      state.nodes.clear();
      state.roots = [];
      state.layout = layout;
      let hidden;
      let hiddenMode;
      if (hiddenSMS) {
        hidden = new Element('phoneLoginDiv'); hidden.visible = false;
        const form = hidden.append(new Element('loginFromId', 'FORM'));
        for (const id of ['username', 'password', 'login_submit']) { form.append(new Element(id, id === 'login_submit' ? 'BUTTON' : 'INPUT')); }
        if (hiddenLoginMode) {
          hiddenMode = form.append(new Element('cllt', 'INPUT', { name: 'cllt', type: 'hidden' }));
          hiddenMode.value = hiddenLoginMode;
        }
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
      // Mirror the public school page's actual password form rather than treating a click as a submission.
      for (const [id, name, value] of [
        ['saltPassword', 'password', ''], ['execution', 'execution', 'offline-execution'],
        ['cllt', 'cllt', 'userNameLogin'], ['pwdEncryptSalt', '', 'offline-salt']
      ]) {
        const input = form.append(new Element(id, 'INPUT', { type: 'hidden', name }));
        input.visible = false;
        input.value = value;
        state.nodes.set(id, input);
      }
      state.pageWindow = {
        needCaptcha: false, captchaSwitch: '2',
        jQuery: Object.assign(() => {}, { isReady: true }),
        encryptPassword: () => 'offline-encrypted-password',
        checkForm: () => {
          if (state.onCheckForm && !state.onCheckForm()) { return false; }
          state.nodes.get('saltPassword').value = state.pageWindow.encryptPassword(
            state.nodes.get('password').value, state.nodes.get('pwdEncryptSalt').value);
          state.nodes.get('password').disabled = true;
          return true;
        }
      };
      state.pageWindow.$ = state.pageWindow.jQuery;
      state.nodes.get('login_submit').onClick = () => {
        state.clicks++;
        if (!state.bindSubmitHandler || !state.pageWindow.checkForm()) { return; }
        if (state.pageWindow.needCaptcha && state.pageWindow.captchaSwitch === '2') {
          const container = new Element('sliderCaptchaDiv');
          container.append(new Element('slider-child'));
          state.roots.push(container);
          state.nodes.set(container.id, container);
          return;
        }
        state.submitted++;
        state.onSubmit?.();
      };
      if (captcha) { state.nodes.set('captcha', form.append(new Element('captcha', 'INPUT'))); }
      return {
        username: state.nodes.get('username'), password: state.nodes.get('password'),
        hiddenUsername: hidden?.querySelector('#username'), hiddenPassword: hidden?.querySelector('#password'), hiddenMode
      };
    },
    showError(message, { visible = true, toast = false } = {}) {
      const id = state.layout === 'mobile' ? 'formErrorTip2' : 'showErrorTip';
      const element = new Element(id); element.textContent = message;
      element.visible = visible;
      state.nodes.set(id, element);
      state.roots.at(-1).append(element);
      if (toast) {
        const alert = new Element('alert-box');
        alert.textContent = message;
        state.roots.push(alert);
        state.nodes.set(alert.id, alert);
      }
    },
    showToast(message) {
      const alert = new Element('alert-box');
      alert.textContent = message;
      state.roots.push(alert);
      state.nodes.set(alert.id, alert);
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
