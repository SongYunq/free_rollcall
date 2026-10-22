import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { APIRequest, APIResponse, HTTPTransport } from '../core/TronclassClient';
import { RollcallError } from '../core/Errors';

/** One authenticated account's memory-only cookie snapshot. Never uses a shared cookie jar. */
export class HarmonyTransport implements HTTPTransport {
  static readonly BASE: string = 'https://lnt.xmu.edu.cn';
  // LNT routes mobile browser identities to c-mobile, which is a separate portal.
  // Authentication and native API requests must use the same desktop service identity.
  static readonly DESKTOP_USER_AGENT: string =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  private cookie: string;
  private userAgent: string;

  constructor(cookie: string, userAgent: string = '') {
    // Header injection must not be possible even if a Web engine returns malformed data.
    if (/[\r\n]/.test(cookie)) { throw new RollcallError('message', '登录状态格式无效，请重新登录'); }
    this.cookie = cookie;
    this.userAgent = userAgent.length > 0 && !/[\r\n]/.test(userAgent) ? userAgent : HarmonyTransport.DESKTOP_USER_AGENT;
  }

  async send(request: APIRequest): Promise<APIResponse> {
    // Relative API paths only: fragments, authority overrides and backslashes are rejected.
    if (!request.path.startsWith('/api/') || /[\r\n\\#]/.test(request.path) ||
      request.path.indexOf('://') >= 0 ||
      (request.method !== 'GET' && request.method !== 'POST' && request.method !== 'PUT')) {
      throw new RollcallError('message', '请求地址或方式无效');
    }
    const headers: rcp.RequestHeaders = {
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'User-Agent': this.userAgent,
      'Accept': request.radarHeaders ? 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' : 'application/json, text/plain, */*',
      'Referer': request.radarHeaders ? 'https://ids.xmu.edu.cn/authserver/login' : 'https://lnt.xmu.edu.cn/user/index',
      'Cookie': this.cookie,
      'Cache-Control': 'no-store'
    };
    if (request.body !== undefined) { headers['Content-Type'] = 'application/json'; }
    // NetworkKit.http follows redirects without exposing a disable switch on API 12.
    // RCP is used so school credentials cannot be forwarded to a redirect target.
    let session: rcp.Session | undefined;
    try {
      session = rcp.createSession({
        requestConfiguration: {
          transfer: { autoRedirect: false, timeout: { connectMs: 20000, transferMs: 35000 } }
        }
      });
      const native = new rcp.Request(HarmonyTransport.BASE + request.path,
        request.method === 'PUT' ? 'PUT' : (request.method === 'POST' ? 'POST' : 'GET'), headers, request.body);
      const response = await session.fetch(native);
      if (response.body !== undefined && response.body.byteLength > 5 * 1024 * 1024) {
        throw new RollcallError('message', '学校返回的数据过大，请稍后重试');
      }
      const body = response.body === undefined ? '' :
        util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(response.body));
      return new APIResponse(response.statusCode, body);
    } catch (error) {
      if (error instanceof RollcallError) { throw error; }
      // A failed write is never retried: the server may already have accepted it.
      if (request.method === 'PUT') {
        throw new RollcallError('uncertain', '提交连接中断，结果待确认，请先核对签到状态');
      }
      throw new RollcallError('message', '网络连接失败或超时，请重试');
    } finally {
      try { session?.close(); } catch (ignored) {}
    }
  }
}
