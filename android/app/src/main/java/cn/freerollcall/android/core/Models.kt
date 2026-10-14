package cn.freerollcall.android.core

import com.google.gson.*
import java.time.*
import java.time.format.DateTimeFormatter

class RollcallException(val reason: Reason, message: String) : Exception(message) {
    enum class Reason { EXPIRED, INVALID_CREDENTIALS, IDENTITY, UNCERTAIN, NETWORK, MALFORMED, OTHER }
    companion object {
        fun expired() = RollcallException(Reason.EXPIRED, "登录已过期，请重新登录")
        fun malformed() = RollcallException(Reason.MALFORMED, "学校响应格式异常，请稍后重试")
        fun message(text: String) = RollcallException(Reason.OTHER, text)
        fun uncertain(text: String) = RollcallException(Reason.UNCERTAIN, text)
    }
}

fun JsonElement.field(key: String): JsonElement? = if (isJsonObject) asJsonObject.get(key) else null
fun JsonElement?.text(): String? = if (this != null && isJsonPrimitive) asJsonPrimitive.asString else null
fun JsonElement?.flag(): Boolean? = if (this != null && isJsonPrimitive && asJsonPrimitive.isBoolean) asBoolean else null
fun JsonElement?.intValue(): Int? = text()?.toIntOrNull()
fun JsonElement?.doubleValue(): Double? = text()?.toDoubleOrNull()
fun JsonElement?.rows(): List<JsonElement>? = if (this?.isJsonArray == true) asJsonArray.toList() else null
fun obj(vararg fields: Pair<String, Any?>): JsonObject = JsonObject().apply {
    for ((key, value) in fields) add(key, when (value) {
        null -> JsonNull.INSTANCE
        is JsonElement -> value
        is String -> JsonPrimitive(value)
        is Number -> JsonPrimitive(value)
        is Boolean -> JsonPrimitive(value)
        else -> error("Unsupported JSON value")
    })
}
fun stringArray(value: String) = JsonArray().apply { add(value) }
private val strictJson = GsonBuilder().setStrictness(Strictness.STRICT).create()
fun parseJson(text: String): JsonElement = try {
    // The lenient parser accepts bare error text and empty bodies as JSON. Those
    // must not turn a damaged submission response into a successful radar result.
    strictJson.fromJson(text, JsonElement::class.java) ?: throw RollcallException.malformed()
}
    catch (_: JsonParseException) { throw RollcallException.malformed() }

data class Profile(val id: String, val account: String, val name: String, val email: String?) {
    fun matches(username: String, knownId: String?): Boolean = if (knownId != null) id == knownId
        else account == username || email?.equals(username, ignoreCase = true) == true
    companion object {
        fun parse(json: JsonElement): Profile {
            val id = json.field("id").text()?.takeIf { it.isNotEmpty() } ?: throw RollcallException.malformed()
            val account = json.field("user_no").text()?.takeIf { it.isNotEmpty() } ?: throw RollcallException.malformed()
            return Profile(id, account, json.field("name").text() ?: account, json.field("email").text())
        }
    }
}
data class Course(val id: String, val name: String) {
    companion object {
        fun parse(json: JsonElement) = Course(
            json.field("id").text() ?: throw RollcallException.malformed(),
            json.field("display_name").text()?.takeIf { it.isNotEmpty() }
                ?: json.field("name").text() ?: "未命名课程")
    }
}
enum class AttendanceKind(val title: String) { NUMBER("数字签到"), RADAR("雷达签到"), OTHER("其他签到"), UNKNOWN("未知形式") }

data class Attendance(
    val id: String, val courseId: String? = null, val courseName: String? = null,
    val rawDate: String? = null, val kind: AttendanceKind = AttendanceKind.UNKNOWN,
    val activityStatus: String? = null, val personalStatus: String? = null,
    val isExpired: Boolean? = null, val numberCode: String? = null, val endTime: Instant? = null
) {
    val date: Instant? = parseTime(rawDate)
    val queryDate: String get() = rollcallDate(rawDate, date)
    val isAnswered get() = personalStatus in answeredStatuses
    val hasEnded get() = isExpired == true || activityStatus in endedStatuses ||
        endTime?.let { !it.isAfter(Instant.now()) } == true
    val isActive get() = !hasEnded && (activityStatus == "active" || isExpired == false)
    val isAbsent get() = hasEnded && personalStatus == "absent"
    val canSubmit get() = isActive && !isAnswered && kind in setOf(AttendanceKind.NUMBER, AttendanceKind.RADAR)
    val stateText get() = when {
        isAnswered -> if (personalStatus in setOf("on_call_late", "late")) "已签到 · 迟到" else "已签到"
        isActive -> "正在签到"
        isAbsent -> "缺勤"
        hasEnded -> "已结束"
        else -> "状态待确认"
    }
    fun merge(other: Attendance): Attendance {
        if (id != other.id) return this
        return copy(courseId = other.courseId ?: courseId, courseName = other.courseName ?: courseName,
            rawDate = other.rawDate ?: rawDate, kind = if (other.kind == AttendanceKind.UNKNOWN) kind else other.kind,
            activityStatus = other.activityStatus ?: activityStatus, personalStatus = other.personalStatus ?: personalStatus,
            isExpired = other.isExpired ?: isExpired, numberCode = other.numberCode ?: numberCode, endTime = other.endTime ?: endTime)
    }
    // Supplementary code reads must not change the history row's attendance result.
    fun withCode(detail: Attendance) = copy(numberCode = detail.numberCode ?: numberCode,
        kind = if (kind == AttendanceKind.UNKNOWN) detail.kind else kind)
    companion object {
        val activityStatuses = setOf("active", "finished", "ended", "closed")
        private val endedStatuses = setOf("finished", "ended", "closed")
        private val answeredStatuses = setOf("on_call_fine", "on_call_late", "present", "attended", "late")
        fun parse(json: JsonElement): Attendance {
            val status = json.field("status").text()
            val radar = json.field("is_radar").flag(); val number = json.field("is_number").flag()
            val code = json.field("number_code").text()
            return Attendance(
                id = json.field("rollcall_id").text() ?: json.field("id").text() ?: throw RollcallException.malformed(),
                courseId = json.field("course_id").text() ?: json.field("course")?.field("id").text(),
                courseName = json.field("course_title").text() ?: json.field("course")?.field("name").text(),
                rawDate = json.field("rollcall_time").text() ?: json.field("created_at").text(),
                kind = when { radar == true -> AttendanceKind.RADAR; number == true -> AttendanceKind.NUMBER
                    radar == false && number == false -> AttendanceKind.OTHER; code != null -> AttendanceKind.NUMBER
                    else -> AttendanceKind.UNKNOWN },
                activityStatus = json.field("rollcall_status").text() ?: status?.takeIf { it in activityStatuses },
                personalStatus = status?.takeUnless { it in activityStatuses },
                isExpired = json.field("is_expired").flag(), numberCode = code,
                endTime = parseTime(json.field("end_time").text()))
        }
    }
}
private val schoolZone = ZoneId.of("Asia/Shanghai")
private val schoolDateFormat = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")
private val displayDateFormat = schoolDateFormat.withZone(schoolZone)
fun parseTime(text: String?): Instant? {
    if (text == null) return null
    return if ('T' in text) runCatching { Instant.parse(text) }.getOrNull()
        else runCatching { LocalDateTime.parse(text, schoolDateFormat).atZone(schoolZone).toInstant() }.getOrNull()
}
fun displayTime(time: Instant): String = displayDateFormat.format(time)
private val schoolDatePattern = DateTimeFormatter.ofPattern("yyyy-MM-dd").withZone(schoolZone)
fun rollcallDate(text: String?, fallback: Instant? = null): String {
    if (text != null && text.matches(Regex("""\d{4}-\d{2}-\d{2}"""))) return text
    val instant = parseTime(text) ?: fallback ?: Instant.now()
    return schoolDatePattern.format(instant)
}
fun validateDate(date: String) {
    if (!date.matches(Regex("""\d{4}-\d{2}-\d{2}""")) || runCatching { LocalDate.parse(date) }.isFailure) {
        throw RollcallException.message("查询日期有误，请使用 YYYY-MM-DD 格式的有效日期")
    }
}

data class DataPage<T>(val items: List<T>, val page: Int, val hasMore: Boolean, val completenessKnown: Boolean)
fun <T> parsePage(json: JsonElement, key: String, page: Int, size: Int, parse: (JsonElement) -> T): DataPage<T> {
    val container = json.field("data")?.takeIf { it.isJsonObject } ?: json
    val rows = container.rows() ?: container.field(key).rows() ?: container.field("data").rows()
        ?: throw RollcallException.malformed()
    val pages = container.field("pages").intValue() ?: json.field("pages").intValue()
    val total = container.field("total").intValue() ?: json.field("total").intValue()
    val more = container.field("has_more").flag() ?: json.field("has_more").flag()
    return DataPage(rows.map(parse), page, rows.isNotEmpty() && (more ?: pages?.let { page < it }
        ?: total?.let { page.toLong() * size < it } ?: true), more != null || pages != null || total != null)
}
data class PageAccumulator<T>(val items: List<T> = emptyList(), val nextPage: Int = 1, val hasMore: Boolean = true, val note: String = "") {
    fun append(page: DataPage<T>, id: (T) -> String): PageAccumulator<T> {
        val seen = items.map(id).toMutableSet()
        val added = page.items.filter { seen.add(id(it)) }
        val duplicate = page.items.isNotEmpty() && added.isEmpty()
        val more = page.hasMore && !duplicate
        return PageAccumulator(items + added, page.page + 1, more, when {
            duplicate -> "学校返回重复记录，当前显示已取得的记录"
            more -> ""
            page.completenessKnown -> "已全部加载"
            else -> "已加载当前可获取的记录"
        })
    }
}
