const messages: Map<string, string> = new Map<string, string>([
  ['expiredSession', '登录已失效，请重新登录当前账号'],
  ['invalidCredentials', '账号或密码未通过认证，请修改后重试'],
  ['identityMismatch', '网页登录账号与所选账号不一致，请使用所选账号重新登录'],
  ['malformedResponse', '返回数据格式发生变化，请稍后重试'],
  ['noDefaultAccount', '请先添加账号并设为默认，或手动登录一个账号'],
  ['cancelled', '已取消']
]);

export class RollcallError extends Error {
  readonly code: string;

  constructor(code: string, message?: string) {
    super(message ?? messages.get(code) ?? '操作未完成，请重试');
    this.name = 'RollcallError';
    this.code = code;
  }
}
