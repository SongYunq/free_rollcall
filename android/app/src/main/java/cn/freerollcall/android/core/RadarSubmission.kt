// Adapted from KrsMt-0113/XMU-Rollcall-Bot c7de02b (verify.py).
// Copyright (c) 2025 KrsMt. MIT License; see THIRD_PARTY_NOTICES.md.
package cn.freerollcall.android.core

import java.util.UUID
import kotlin.math.*

data class Coordinate(val latitude: Double, val longitude: Double)
object RadarSubmission {
    val first = Coordinate(24.3, 118.0)
    val second = Coordinate(24.6, 118.2)
    fun payload(point: Coordinate, deviceId: String = UUID.randomUUID().toString()) = obj(
        "accuracy" to 35, "altitude" to 0, "altitudeAccuracy" to null, "deviceId" to deviceId,
        "heading" to null, "latitude" to point.latitude, "longitude" to point.longitude, "speed" to null)
    fun solve(distance1: Double, distance2: Double): List<Coordinate>? {
        if (!distance1.isFinite() || !distance2.isFinite() || distance1 < 0 || distance2 < 0) return null
        val radius = 6_371_000.0
        val lat0 = (first.latitude + second.latitude) / 2; val lon0 = (first.longitude + second.longitude) / 2
        fun xy(p: Coordinate) = Pair(Math.toRadians(p.longitude - lon0) * radius * cos(Math.toRadians(lat0)),
            Math.toRadians(p.latitude - lat0) * radius)
        val (x1, y1) = xy(first); val (x2, y2) = xy(second)
        val d = hypot(x2 - x1, y2 - y1)
        if (d == 0.0 || d > distance1 + distance2 || d < abs(distance1 - distance2)) return null
        val a = (distance1 * distance1 - distance2 * distance2 + d * d) / (2 * d)
        val hSquared = distance1 * distance1 - a * a
        if (hSquared < 0) return null
        val h = sqrt(hSquared)
        val xm = x1 + a * (x2 - x1) / d; val ym = y1 + a * (y2 - y1) / d
        val rx = -(y2 - y1) * h / d; val ry = (x2 - x1) * h / d
        fun latlon(x: Double, y: Double) = Coordinate(lat0 + Math.toDegrees(y / radius),
            lon0 + Math.toDegrees(x / (radius * cos(Math.toRadians(lat0)))))
        return listOf(latlon(xm + rx, ym + ry), latlon(xm - rx, ym - ry))
    }
    suspend fun run(transport: Transport, id: String): Boolean {
        suspend fun send(point: Coordinate): ApiResponse {
            val response = transport.send(ApiRequest("/api/rollcall/$id/answer", "PUT", payload(point), true))
            // Keep the bot's probe order for distance responses, but never continue sending
            // after an expired session or an ambiguous server failure.
            if (response.status in setOf(401, 403) || response.status in 300..399)
                throw RollcallException.expired()
            if (response.status >= 500 || response.status == 408)
                throw RollcallException.uncertain("学校服务响应异常，签到结果尚未确认，请先核对签到状态")
            if (response.status == 200 && response.isLoginPage()) throw RollcallException.expired()
            return response
        }
        fun parseProbe(response: ApiResponse) = try { response.json() }
        catch (error: RollcallException) {
            // HTTP 200 may already mean the write succeeded, even if its body is damaged.
            if (response.status == 200) throw RollcallException.uncertain("学校返回内容异常，签到结果尚未确认，请先核对签到状态")
            throw error
        }
        val r1 = send(first); val j1 = parseProbe(r1)
        if (r1.status == 200) return true
        val r2 = send(second); val j2 = parseProbe(r2)
        if (r2.status == 200) return true
        val d1 = j1.field("distance").doubleValue(); val d2 = j2.field("distance").doubleValue()
        if (d1 == null || d2 == null) throw RollcallException.message("雷达响应缺少距离信息，本次签到未完成")
        val candidates = solve(d1, d2) ?: return false
        val r3 = send(candidates[0])
        if (r3.status == 200) return true
        r3.json()
        return send(candidates[1]).status == 200
    }
}
