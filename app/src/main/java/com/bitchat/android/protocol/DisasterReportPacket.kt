package com.bitchat.android.protocol

import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Health Report Payload - Synchronized with Flutter health_report.dart
 */
data class HealthReportPayload(
    val reporterId: String,   // 回報者 ID
    val name: String,         // 姓名
    val phone: String,        // 手機
    val bloodType: String?,   // 血型
    val status: String,       // '安全' / '輕傷' / '重傷'
    val description: String?, // 補充說明
    val lat: Double?,         // 緯度
    val lng: Double?,         // 經度
    val reportTime: String    // ISO8601 時間字串
) {
    fun encode(): ByteArray {
        // 使用簡單的字串長度編碼或 JSON。考量到與 Flutter 對接方便，這裡採用與 Flutter 相同的欄位結構。
        // 為求效能與穩定，我們定義一個二進位格式：
        val reporterIdBytes = reporterId.toByteArray(Charsets.UTF_8)
        val nameBytes = name.toByteArray(Charsets.UTF_8)
        val phoneBytes = phone.toByteArray(Charsets.UTF_8)
        val bloodTypeBytes = bloodType?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)
        val statusBytes = status.toByteArray(Charsets.UTF_8)
        val descriptionBytes = description?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)
        val reportTimeBytes = reportTime.toByteArray(Charsets.UTF_8)

        val size = 1 + reporterIdBytes.size + 
                   1 + nameBytes.size + 
                   1 + phoneBytes.size + 
                   1 + bloodTypeBytes.size + 
                   1 + statusBytes.size + 
                   2 + descriptionBytes.size + 
                   16 + // Lat(8) + Lng(8)
                   1 + reportTimeBytes.size

        val buffer = ByteBuffer.allocate(size).apply { order(ByteOrder.BIG_ENDIAN) }
        
        // Write Fields
        buffer.put(reporterIdBytes.size.toByte())
        buffer.put(reporterIdBytes)
        
        buffer.put(nameBytes.size.toByte())
        buffer.put(nameBytes)
        
        buffer.put(phoneBytes.size.toByte())
        buffer.put(phoneBytes)
        
        buffer.put(bloodTypeBytes.size.toByte())
        buffer.put(bloodTypeBytes)
        
        buffer.put(statusBytes.size.toByte())
        buffer.put(statusBytes)
        
        buffer.putShort(descriptionBytes.size.toShort())
        buffer.put(descriptionBytes)
        
        buffer.putDouble(lat ?: 0.0)
        buffer.putDouble(lng ?: 0.0)
        
        buffer.put(reportTimeBytes.size.toByte())
        buffer.put(reportTimeBytes)
        
        return buffer.array()
    }

    companion object {
        private const val TAG = "HealthReportPayload"
        
        fun decode(data: ByteArray): HealthReportPayload? {
            try {
                Log.d(TAG, "🔍 開始解碼，資料長度: ${data.size} 字節")
                
                // 輸出前 32 個字節用於調試
                val hexPreview = data.take(32).joinToString(" ") { String.format("%02X", it) }
                Log.d(TAG, "資料預覽 (前32字節): $hexPreview")
                
                val buffer = ByteBuffer.wrap(data).apply { order(ByteOrder.BIG_ENDIAN) }
                
                // 讀取報告者 ID
                val ridLen = buffer.get().toInt() and 0xFF
                Log.d(TAG, "reporterId 長度: $ridLen (預期 < 256)")
                if (ridLen < 0 || ridLen > 255 || ridLen > buffer.remaining()) {
                    Log.w(TAG, "❌ reporterId 長度異常: $ridLen，剩餘: ${buffer.remaining()}")
                    return null
                }
                val reporterIdBytes = ByteArray(ridLen)
                buffer.get(reporterIdBytes)
                val reporterId = String(reporterIdBytes, Charsets.UTF_8)
                Log.d(TAG, "✓ reporterId: '$reporterId'")
                
                // 讀取姓名
                val nLen = buffer.get().toInt() and 0xFF
                Log.d(TAG, "name 長度: $nLen")
                if (nLen < 0 || nLen > 255 || nLen > buffer.remaining()) {
                    Log.w(TAG, "❌ name 長度異常: $nLen，剩餘: ${buffer.remaining()}")
                    return null
                }
                val nameBytes = ByteArray(nLen)
                buffer.get(nameBytes)
                val name = String(nameBytes, Charsets.UTF_8)
                Log.d(TAG, "✓ name: '$name'")
                
                // 讀取電話
                val pLen = buffer.get().toInt() and 0xFF
                Log.d(TAG, "phone 長度: $pLen")
                if (pLen < 0 || pLen > 255 || pLen > buffer.remaining()) {
                    Log.w(TAG, "❌ phone 長度異常: $pLen，剩餘: ${buffer.remaining()}")
                    return null
                }
                val phoneBytes = ByteArray(pLen)
                buffer.get(phoneBytes)
                val phone = String(phoneBytes, Charsets.UTF_8)
                Log.d(TAG, "✓ phone: '$phone'")
                
                // 讀取血型
                val btLen = buffer.get().toInt() and 0xFF
                Log.d(TAG, "bloodType 長度: $btLen")
                val bloodType = if (btLen > 0 && btLen <= 255 && btLen <= buffer.remaining()) {
                    val btBytes = ByteArray(btLen)
                    buffer.get(btBytes)
                    String(btBytes, Charsets.UTF_8)
                } else {
                    null
                }
                Log.d(TAG, "✓ bloodType: '${bloodType ?: "null"}'")
                
                // 讀取狀態
                val sLen = buffer.get().toInt() and 0xFF
                Log.d(TAG, "status 長度: $sLen")
                if (sLen < 0 || sLen > 255 || sLen > buffer.remaining()) {
                    Log.w(TAG, "❌ status 長度異常: $sLen，剩餘: ${buffer.remaining()}")
                    return null
                }
                val statusBytes = ByteArray(sLen)
                buffer.get(statusBytes)
                val status = String(statusBytes, Charsets.UTF_8)
                Log.d(TAG, "✓ status: '$status'")
                
                // 讀取補充說明
                if (buffer.remaining() < 2) {
                    Log.w(TAG, "❌ description 長度欄位不足，剩餘: ${buffer.remaining()}")
                    return null
                }
                val dLen = buffer.getShort().toInt() and 0xFFFF
                Log.d(TAG, "description 長度: $dLen (2字節大端序)")
                val description = if (dLen > 0 && dLen <= buffer.remaining()) {
                    val dBytes = ByteArray(dLen)
                    buffer.get(dBytes)
                    String(dBytes, Charsets.UTF_8)
                } else {
                    null
                }
                Log.d(TAG, "✓ description: '${description ?: "null"}'")
                
                // 讀取座標
                if (buffer.remaining() < 16) {
                    Log.w(TAG, "❌ 座標資料不足，需要16字節，剩餘: ${buffer.remaining()}")
                    return null
                }
                val latVal = buffer.getDouble()
                val lngVal = buffer.getDouble()
                val lat = if (latVal == 0.0) null else latVal
                val lng = if (lngVal == 0.0) null else lngVal
                Log.d(TAG, "✓ lat: $lat, lng: $lng")
                
                // 讀取時間
                if (buffer.remaining() < 1) {
                    Log.w(TAG, "❌ reportTime 長度欄位不足")
                    return null
                }
                val tLen = buffer.get().toInt() and 0xFF
                Log.d(TAG, "reportTime 長度: $tLen")
                if (tLen < 0 || tLen > 255 || tLen > buffer.remaining()) {
                    Log.w(TAG, "❌ reportTime 長度異常: $tLen，剩餘: ${buffer.remaining()}")
                    return null
                }
                val reportTimeBytes = ByteArray(tLen)
                buffer.get(reportTimeBytes)
                val reportTime = String(reportTimeBytes, Charsets.UTF_8)
                Log.d(TAG, "✓ reportTime: '$reportTime'")
                
                if (buffer.remaining() > 0) {
                    Log.w(TAG, "⚠️  解碼完成但還有 ${buffer.remaining()} 字節未讀")
                }
                
                Log.d(TAG, "✅ 解碼成功！")
                return HealthReportPayload(
                    reporterId, name, phone, bloodType, status, description, lat, lng, reportTime
                )
            } catch (e: Exception) {
                Log.e(TAG, "❌ 解碼失敗: ${e.message}, 堆疊追蹤:", e)
                return null
            }
        }
    }
}
