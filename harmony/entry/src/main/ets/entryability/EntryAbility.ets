import { ConfigurationConstant, UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { releaseRuntime } from '../platform/AppRuntime';

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (error) {
      hilog.warn(0x0000, 'FreeRollcall', 'Unable to set application color mode');
    }
    try {
      windowStage.loadContent('pages/Index', (error: BusinessError): void => {
        if (error.code !== 0) { hilog.error(0x0000, 'FreeRollcall', 'Unable to load the main page'); }
      });
    } catch (error) {
      hilog.error(0x0000, 'FreeRollcall', 'Unable to start the main page');
    }
  }

  onDestroy(): void {
    releaseRuntime();
  }
}
