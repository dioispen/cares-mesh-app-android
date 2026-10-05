package com.bitchat.android.experiment

import com.bitchat.android.experiment.ExperimentEvent.Companion.id8
import com.bitchat.android.flutter.BridgeMethodHandler
import com.bitchat.android.flutter.invalidArguments
import com.bitchat.android.protocol.HealthStatus
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException

/**
 * debug build 才註冊的 bridge method（#70），給 Flutter 的現場計數畫面用；release build 沒有這個
 * 類別，這些 method 一律 `notImplemented`。Dart 端對應 `ExperimentMethods`／`ExperimentErrors`。
 *
 * - [METHOD_GET_STATUS]：直連數、電源模式、本機 peerID 前 8 碼、最近 20 s／60 s 依實驗 handle 的
 *   `RX` 筆數，以及發送器狀態（[senderStatus]）。
 * - [METHOD_START_SENDER]：`{device: 1..7, count: >=1, intervalMs: >=0, ttl: 3|7,
 *   startAt: "HH:mm:ss"|null, status: Status label}`，回傳發送器狀態。
 * - [METHOD_STOP_SENDER]：停止發送器，回傳發送器狀態。
 *
 * [sender] 在 `MeshForegroundService` 存在時才有；沒有時開始會回 [ERROR_SERVICE_NOT_READY]。
 */
class ExperimentBridge(
    private val probe: MeshProbe,
    private val rxCounter: ExperimentRxCounter,
    private val sender: () -> ExperimentSender?
) : BridgeMethodHandler {

    override fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            METHOD_GET_STATUS -> result.success(status())
            METHOD_START_SENDER -> start(call, result)
            METHOD_STOP_SENDER -> result.success(senderStatus(sender()?.stop()))
            else -> return false
        }
        return true
    }

    private fun status(): Map<String, Any?> = mapOf(
        "links" to probe.linkCount(),
        "powerMode" to probe.powerMode(),
        "peerId" to probe.myPeerID()?.let(::id8),
        "rx20s" to rxCounter.countsWithin(20_000),
        "rx60s" to rxCounter.countsWithin(60_000),
        "sender" to senderStatus(sender()?.status)
    )

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val plan = planFrom(call.arguments as? Map<*, *>)
            ?: return result.invalidArguments(
                call,
                "{device: 1..7, count: >=1, intervalMs: >=0, ttl: 3|7, startAt: HH:mm:ss|null, status: String}"
            )
        val sender = sender()
            ?: return result.error(ERROR_SERVICE_NOT_READY, "Mesh foreground service is not running", null)
        when (val started = sender.start(plan)) {
            is ExperimentSender.StartResult.Started -> result.success(senderStatus(started.status))
            ExperimentSender.StartResult.AlreadyRunning ->
                result.error(ERROR_ALREADY_RUNNING, "The experiment sender is already running", null)
        }
    }

    companion object {
        const val METHOD_GET_STATUS = "experiment_getStatus"
        const val METHOD_START_SENDER = "experiment_startSender"
        const val METHOD_STOP_SENDER = "experiment_stopSender"

        /** 與 `BridgeArguments` 的 `INVALID_ARGUMENT` 同值：參數錯誤由共用的 `invalidArguments` 回覆。 */
        const val ERROR_INVALID_ARGUMENT = "INVALID_ARGUMENT"
        const val ERROR_SERVICE_NOT_READY = "SERVICE_NOT_READY"
        const val ERROR_ALREADY_RUNNING = "ALREADY_RUNNING"

        private val START_AT_FORMAT = DateTimeFormatter.ofPattern("HH:mm:ss")

        /** [METHOD_START_SENDER] 的參數；任何一個缺少、型別不對或超出範圍都回傳 null。 */
        internal fun planFrom(arguments: Map<*, *>?): ExperimentPlan? {
            arguments ?: return null
            val device = arguments.integer("device")?.takeIf { it in ExperimentHandles.DEVICES } ?: return null
            val count = arguments.integer("count")?.takeIf { it in 1..Int.MAX_VALUE } ?: return null
            val intervalMs = arguments.integer("intervalMs")?.takeIf { it >= 0 } ?: return null
            val ttl = arguments.integer("ttl")
                ?.let { value -> ExperimentPlan.TTLS.firstOrNull { it.toLong() == value } }
                ?: return null
            val status = (arguments["status"] as? String)?.let(HealthStatus::fromLabel) ?: return null
            val startAt = when (val raw = arguments["startAt"]) {
                null -> null
                is String -> try {
                    LocalTime.parse(raw, START_AT_FORMAT)
                } catch (_: DateTimeParseException) {
                    return null
                }
                else -> return null
            }
            return ExperimentPlan(
                handle = ExperimentHandles.forDevice(device.toInt()),
                status = status,
                count = count.toInt(),
                intervalMs = intervalMs,
                ttl = ttl,
                startAt = startAt
            )
        }

        /** Dart 的 int 到這裡是 Int 或 Long；double 等其他型別一律不算。 */
        private fun Map<*, *>.integer(key: String): Long? = when (val value = this[key]) {
            is Int -> value.toLong()
            is Long -> value
            else -> null
        }

        /** 發送器狀態；沒有發送器時是 `idle`。 */
        internal fun senderStatus(status: ExperimentSender.Status?): Map<String, Any?> {
            val current = status ?: ExperimentSender.Status(ExperimentSender.State.IDLE)
            return mapOf(
                "state" to current.state.name.lowercase(),
                "sent" to current.sent,
                "failed" to current.failed,
                "total" to current.total,
                "startsAtMs" to current.startsAtMs,
                "handle" to current.plan?.handle,
                "ttl" to current.plan?.ttl,
                "intervalMs" to current.plan?.intervalMs
            )
        }
    }
}
