import { common } from '@kit.AbilityKit';
import { AppModel } from '../app/AppModel';
import { SecureStore } from './SecureStore';
import { WebAuthenticator } from './WebAuthenticator';

export class AppRuntime {
  model: AppModel;
  authenticator: WebAuthenticator;

  constructor(context: common.UIAbilityContext) {
    this.authenticator = new WebAuthenticator();
    this.model = new AppModel(new SecureStore(context), this.authenticator);
  }
}

let runtime: AppRuntime | undefined;

export function getRuntime(context: common.UIAbilityContext): AppRuntime {
  if (runtime === undefined) { runtime = new AppRuntime(context); }
  return runtime;
}

export function releaseRuntime(): void {
  if (runtime !== undefined) {
    runtime.authenticator.cancel();
    runtime.model.logout();
    runtime.model.onChange = (): void => {};
    runtime = undefined;
  }
}
