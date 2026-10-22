import { RollcallError } from './Errors';

/** JSON parsing stays in TypeScript; ArkTS callers only see explicitly typed models. */
export class JSONValue {
  private constructor(private value: unknown) {}

  static decode(text: string): JSONValue {
    try { return new JSONValue(JSON.parse(text) as unknown); }
    catch (_) { throw new RollcallError('malformedResponse'); }
  }

  field(key: string): JSONValue {
    if (!this.isObject) { return new JSONValue(undefined); }
    return new JSONValue((this.value as { [key: string]: unknown })[key]);
  }

  get isObject(): boolean {
    return this.value !== null && typeof this.value === 'object' && !Array.isArray(this.value);
  }

  get isNull(): boolean { return this.value === null || this.value === undefined; }

  get array(): JSONValue[] | undefined {
    if (!Array.isArray(this.value)) { return undefined; }
    return this.value.map((entry: unknown): JSONValue => new JSONValue(entry));
  }

  get string(): string | undefined {
    if (typeof this.value === 'string') { return this.value; }
    if (typeof this.value === 'number' && Number.isFinite(this.value)) { return String(this.value); }
    return undefined;
  }

  get number(): number | undefined {
    if (typeof this.value === 'number') { return this.value; }
    if (typeof this.value === 'string' && this.value.trim().length > 0) {
      const result = Number(this.value);
      if (Number.isFinite(result)) { return result; }
    }
    return undefined;
  }

  get integer(): number | undefined {
    const value = this.number;
    return value !== undefined && Number.isSafeInteger(value) && value >= 0 ? value : undefined;
  }

  get boolean(): boolean | undefined {
    return typeof this.value === 'boolean' ? this.value : undefined;
  }
}
