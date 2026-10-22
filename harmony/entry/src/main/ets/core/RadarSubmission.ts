// Adapted from KrsMt-0113/XMU-Rollcall-Bot c7de02b (verify.py).
// Copyright (c) 2025 KrsMt. MIT License; see THIRD_PARTY_NOTICES.md.
import { APIRequest, APIResponse, HTTPTransport } from './TronclassClient';
import { RollcallError } from './Errors';

export class Coordinate {
  constructor(public latitude: number, public longitude: number) {}
}

/** A per-request identifier, not an authentication secret or persistent device identity. */
export function randomDeviceID(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (character: string): string => {
    const random = Math.floor(Math.random() * 16);
    return (character === 'x' ? random : ((random & 0x3) | 0x8)).toString(16);
  });
}

export class RadarSubmission {
  static readonly first: Coordinate = new Coordinate(24.3, 118.0);
  static readonly second: Coordinate = new Coordinate(24.6, 118.2);

  static payload(point: Coordinate, deviceID: string = randomDeviceID()): string {
    return JSON.stringify({ accuracy: 35, altitude: 0, altitudeAccuracy: null, deviceId: deviceID,
      heading: null, latitude: point.latitude, longitude: point.longitude, speed: null });
  }

  static solve(distance1: number, distance2: number): Coordinate[] | undefined {
    if (!Number.isFinite(distance1) || !Number.isFinite(distance2) || distance1 < 0 || distance2 < 0) { return undefined; }
    const radius = 6371000;
    const lat0 = (RadarSubmission.first.latitude + RadarSubmission.second.latitude) / 2;
    const lon0 = (RadarSubmission.first.longitude + RadarSubmission.second.longitude) / 2;
    const radians = (value: number): number => value * Math.PI / 180;
    const degrees = (value: number): number => value * 180 / Math.PI;
    const x1 = radians(RadarSubmission.first.longitude - lon0) * radius * Math.cos(radians(lat0));
    const y1 = radians(RadarSubmission.first.latitude - lat0) * radius;
    const x2 = radians(RadarSubmission.second.longitude - lon0) * radius * Math.cos(radians(lat0));
    const y2 = radians(RadarSubmission.second.latitude - lat0) * radius;
    const distance = Math.hypot(x2 - x1, y2 - y1);
    if (distance <= 0 || distance > distance1 + distance2 || distance < Math.abs(distance1 - distance2)) { return undefined; }
    const a = (distance1 * distance1 - distance2 * distance2 + distance * distance) / (2 * distance);
    const hSquared = distance1 * distance1 - a * a;
    if (hSquared < 0) { return undefined; }
    const h = Math.sqrt(hSquared);
    const xm = x1 + a * (x2 - x1) / distance;
    const ym = y1 + a * (y2 - y1) / distance;
    const rx = -(y2 - y1) * h / distance;
    const ry = (x2 - x1) * h / distance;
    const latlon = (x: number, y: number): Coordinate => new Coordinate(lat0 + degrees(y / radius),
      lon0 + degrees(x / (radius * Math.cos(radians(lat0)))));
    return [latlon(xm + rx, ym + ry), latlon(xm - rx, ym - ry)];
  }

  static async run(transport: HTTPTransport, id: string): Promise<boolean> {
    const send = async (point: Coordinate): Promise<APIResponse> => {
      return transport.send(new APIRequest(`/api/rollcall/${id}/answer`, 'PUT', RadarSubmission.payload(point), true));
    };
    const r1 = await send(RadarSubmission.first);
    const j1 = r1.json(); // Preserve the iOS/reference response-decoding order.
    if (r1.status === 200) { return true; }
    const r2 = await send(RadarSubmission.second);
    const j2 = r2.json();
    if (r2.status === 200) { return true; }
    const d1 = j1.field('distance').number;
    const d2 = j2.field('distance').number;
    if (d1 === undefined || d2 === undefined) { throw new RollcallError('message', '雷达响应缺少距离信息，本次签到未完成'); }
    const candidates = RadarSubmission.solve(d1, d2);
    if (candidates === undefined) { return false; }
    const r3 = await send(candidates[0]);
    if (r3.status === 200) { return true; }
    r3.json();
    const r4 = await send(candidates[1]);
    return r4.status === 200;
  }
}
