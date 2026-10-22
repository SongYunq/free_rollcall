import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppData, AppStorage, AttendanceLog, SavedAccount } from '../app/Contracts';
import { RollcallError } from '../core/Errors';

/** Preferences stores metadata; the OS Asset Store protects passwords independently. */
export class SecureStore implements AppStorage {
  private context: common.Context;
  private metadata?: preferences.Preferences;

  constructor(context: common.Context) { this.context = context; }

  private async database(): Promise<preferences.Preferences> {
    if (this.metadata === undefined) {
      try {
        this.metadata = await preferences.getPreferences(this.context, { name: 'free_rollcall_v1' });
      } catch (error) {
        throw new RollcallError('message', '本地存储打开失败，请检查应用存储后重试');
      }
    }
    return this.metadata;
  }

  async load(): Promise<AppData> {
    try {
      const database = await this.database();
      const encoded = await database.get('metadata', '');
      if (typeof encoded !== 'string' || encoded.length === 0) { return new AppData(); }
      const decoded = JSON.parse(encoded) as AppData;
      if (decoded.version !== 1 || !Array.isArray(decoded.accounts) || !Array.isArray(decoded.logs)) {
        throw new Error('metadata shape');
      }
      return this.copyMetadata(decoded);
    } catch (error) {
      throw new RollcallError('message', '本地记录读取失败，请检查应用存储后重试');
    }
  }

  async save(data: AppData): Promise<void> {
    const encoded = JSON.stringify(this.copyMetadata(data));
    const database = await this.database();
    let old: preferences.ValueType;
    try {
      old = await database.get('metadata', '');
    } catch (error) {
      throw new RollcallError('message', '本地记录读取失败，本次未保存，请重试');
    }
    try {
      await database.put('metadata', encoded);
      await database.flush();
    } catch (error) {
      // Restore the in-process preference value too, so a failed save cannot leak into a later flush.
      try { await database.put('metadata', old); await database.flush(); } catch (ignored) {}
      throw new RollcallError('message', '本地记录保存失败，请检查存储空间后重试');
    }
  }

  private alias(id: string): asset.AssetMap {
    if (id.length === 0 || id.length > 120 || /[^a-zA-Z0-9_-]/.test(id)) {
      throw new RollcallError('message', '账号标识无效，请重新添加账号');
    }
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto('cn.free-rollcall.' + id));
    return query;
  }

  async readPassword(id: string): Promise<string> {
    try {
      const query = this.alias(id);
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const results = await asset.query(query);
      if (results.length !== 1) { throw new Error('missing'); }
      const secret = results[0].get(asset.Tag.SECRET);
      if (!(secret instanceof Uint8Array)) { throw new Error('missing'); }
      const password = util.TextDecoder.create('utf-8').decodeToString(secret);
      secret.fill(0);
      if (password.length === 0) { throw new Error('empty'); }
      return password;
    } catch (error) {
      throw new RollcallError('message', '无法读取保存的密码，请解锁设备或重新编辑该账号');
    }
  }

  async writePassword(id: string, password: string): Promise<void> {
    if (password.length === 0) { throw new RollcallError('message', '密码不能为空'); }
    const secret = new util.TextEncoder().encodeInto(password);
    try {
      const attributes = this.alias(id);
      attributes.set(asset.Tag.SECRET, secret);
      attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
      attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
      attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
      // IS_PERSISTENT is deliberately omitted: credentials are removed when the app is uninstalled.
      await asset.add(attributes);
    } catch (error) {
      throw new RollcallError('message', '密码安全保存失败，请解锁设备后重试');
    } finally {
      secret.fill(0);
    }
  }

  async deletePassword(id: string): Promise<void> {
    try { await asset.remove(this.alias(id)); }
    catch (error) {
      if ((error as BusinessError).code !== 24000002) {
        throw new RollcallError('message', '密码删除失败，请解锁设备后重试');
      }
    }
  }

  // Explicit field copies restore class getters after JSON decoding and exclude accidental secret fields.
  private copyMetadata(source: AppData): AppData {
    const target = new AppData();
    target.accounts = source.accounts.map((item: SavedAccount): SavedAccount => {
      if (typeof item.id !== 'string' || typeof item.username !== 'string' ||
        typeof item.note !== 'string' || !Number.isFinite(item.createdAt)) { throw new Error('account shape'); }
      const account = new SavedAccount();
      account.id = item.id;
      account.username = item.username;
      account.note = item.note;
      account.isDefault = item.isDefault === true;
      account.verifiedStudentID = item.verifiedStudentID;
      account.createdAt = item.createdAt;
      return account;
    });
    target.logs = source.logs.map((item: AttendanceLog): AttendanceLog => {
      if (typeof item.id !== 'string' || typeof item.accountID !== 'string' ||
        typeof item.username !== 'string' || typeof item.courseID !== 'string' ||
        typeof item.rollcallID !== 'string' || !Number.isFinite(item.createdAt)) { throw new Error('log shape'); }
      const log = new AttendanceLog();
      log.id = item.id;
      log.createdAt = item.createdAt;
      log.completedAt = item.completedAt;
      log.accountID = item.accountID;
      log.username = item.username;
      log.accountNote = item.accountNote;
      log.studentID = item.studentID;
      log.courseID = item.courseID;
      log.courseName = item.courseName;
      log.rollcallID = item.rollcallID;
      log.rollcallDate = item.rollcallDate;
      log.kind = item.kind;
      log.code = item.code;
      log.result = item.result;
      log.message = item.message;
      return log;
    });
    return target;
  }
}
