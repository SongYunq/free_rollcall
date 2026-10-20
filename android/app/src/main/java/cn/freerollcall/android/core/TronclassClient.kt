package cn.freerollcall.android.core

import com.google.gson.JsonElement
import kotlinx.coroutines.*
import java.util.UUID

internal fun ApiResponse.isLoginPage(): Boolean =
    body.take(200).contains("<html", true) || body.trimStart().startsWith("<!DOCTYPE", true)

class TronclassClient(val transport: Transport, private val wait: suspend (Long) -> Unit = { delay(it) }) {
    private suspend fun read(request: ApiRequest): JsonElement {
        val response = transport.send(request)
        if (response.status in setOf(401, 403) || response.status in 300..399) throw RollcallException.expired()
        if (response.status != 200) throw RollcallException.message("学校服务暂时不可用（${response.status}）")
        if (response.isLoginPage()) throw RollcallException.expired()
        return response.json()
    }
    suspend fun profile() = Profile.parse(read(ApiRequest("/api/profile")))
    suspend fun currentSemesterCourses(): List<Course> {
        val term = read(ApiRequest("/api/current-semester-info"))
        val semester = term.field("semester")?.field("id").text()?.takeIf { it.isNotEmpty() }
            ?: throw RollcallException.message("未能获取当前学期，请稍后重试")
        val year = term.field("academic_year")?.field("id").text()?.takeIf { it.isNotEmpty() }
            ?: throw RollcallException.message("未能获取当前学期，请稍后重试")
        val conditions = obj("semester_id" to stringArray(semester), "academic_year_id" to stringArray(year),
            "keyword" to "", "classify_type" to "recently_started", "display_studio_list" to false)
        var pages = PageAccumulator<Course>()
        do {
            currentCoroutineContext().ensureActive()
            val body = obj("conditions" to conditions, "fields" to "id,name,display_name", "page" to pages.nextPage,
                "page_size" to 30, "showScorePassedStatus" to false)
            val json = read(ApiRequest("/api/my-courses", "POST", body))
            pages = pages.append(parsePage(json, "courses", pages.nextPage, 30, Course::parse), Course::id)
        } while (pages.hasMore)
        return pages.items
    }
    suspend fun history(courseId: String, studentId: String, page: Int): DataPage<Attendance> {
        validateId(courseId); validateId(studentId)
        return parsePage(read(ApiRequest("/api/course/$courseId/student/$studentId/rollcalls?page=$page&page_size=99")),
            "rollcalls", page, 99, Attendance::parse)
    }
    suspend fun active(): List<Attendance> {
        val json = read(ApiRequest("/api/radar/rollcalls"))
        return (json.field("rollcalls").rows() ?: json.rows() ?: throw RollcallException.malformed()).map(Attendance::parse)
    }
    suspend fun timetableRollcalls(courseId: String, date: String): List<JsonElement> {
        validateId(courseId); validateDate(date)
        val json = read(ApiRequest("/api/timetable_rollcalls?course_ids=$courseId&rollcall_date=$date"))
        if (!json.isJsonObject) throw RollcallException.malformed()
        val rows = json.field("rollcalls").rows() ?: throw RollcallException.malformed()
        return rows.filter { row ->
            if (!row.isJsonObject) throw RollcallException.malformed()
            val returnedCourseId = row.field("course")?.field("id").text() ?: row.field("course_id").text()
            returnedCourseId == null || returnedCourseId == courseId
        }
    }
    suspend fun detail(courseId: String, id: String, date: String, studentId: String): Attendance {
        validateId(courseId); validateId(id); validateId(studentId)
        validateDate(date)
        val rows = timetableRollcalls(courseId, date)
        val item = rows.firstOrNull {
            val rid = it.field("id").text() ?: it.field("rollcall_id").text()
            rid == id
        } ?: throw RollcallException.message("该日期的查询结果中未找到本次签到")
        return parseDetail(item, studentId)
    }
    suspend fun details(courseId: String, date: String, studentId: String): List<Attendance> {
        validateId(studentId)
        return timetableRollcalls(courseId, date).map { parseDetail(it, studentId) }
    }
    private fun parseDetail(item: JsonElement, studentId: String): Attendance {
        val id = item.field("id").text() ?: item.field("rollcall_id").text() ?: throw RollcallException.malformed()
        val fields = item.asJsonObject.deepCopy().apply { addProperty("rollcall_id", id) }
        val own = item.field("student_rollcalls").rows()?.firstOrNull { it.field("student_id").text() == studentId }
        return Attendance.parse(fields).copy(personalStatus = own?.field("status").text())
    }
    suspend fun detail(id: String, studentId: String): Attendance =
        detail("1", id, rollcallDate(null), studentId)
    suspend fun submitNumber(id: String, code: String, studentId: String, courseId: String = "1", date: String = rollcallDate(null)): Attendance {
        // Validate the identity needed for read-back before making any remote write.
        validateId(id); validateId(studentId)
        if (courseId.isNotEmpty()) validateId(courseId)
        if (code.isEmpty()) throw RollcallException.message("未能取得数字签到码")
        val response = transport.send(ApiRequest("/api/rollcall/$id/answer_number_rollcall", "PUT",
            obj("deviceId" to UUID.randomUUID().toString(), "numberCode" to code)))
        if (response.status in setOf(401, 403) || response.status in 300..399)
            throw RollcallException.expired()
        if (response.status >= 500 || response.status == 408) throw RollcallException.uncertain("学校服务响应异常，签到结果尚未确认")
        if (response.status == 200 && response.isLoginPage()) throw RollcallException.expired()
        if (response.status != 200) throw RollcallException.message("签到未通过（${response.status}），请刷新后重试")
        if (runCatching { response.json().field("success").flag() }.getOrNull() == false)
            throw RollcallException.message("学校未接受本次签到，请刷新后重试")
        // Eventual consistency: read back up to three times, never repeat the PUT.
        for (attempt in 0..2) {
            if (attempt > 0) wait(800L * attempt)
            try {
                val record = detail(courseId, id, date, studentId)
                if (record.isAnswered) return record
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { /* An accepted request can outlive a failed status query. */ }
        }
        throw RollcallException.uncertain("已提交，暂未查到本人签到结果，可稍后核对")
    }
    suspend fun submitRadar(id: String): Boolean { validateId(id); return RadarSubmission.run(transport, id) }
    private fun validateId(id: String) {
        if (id.isEmpty() || id.any { it !in '0'..'9' }) throw RollcallException.malformed()
    }
}
