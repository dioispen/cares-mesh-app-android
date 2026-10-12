package com.bitchat.android.flutter

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.lifecycleScope
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

/**
 * `pickAvatarPhoto`：從裝置挑一張照片當大頭貼，回傳裁成正方形、縮成 [OUTPUT_SIZE] 的 JPEG。
 *
 * 用 AndroidX 的系統照片選擇器（[ActivityResultContracts.PickVisualMedia]），不需要任何儲存權限，
 * 也不引入新套件——新增依賴得同步更新 STRICT 的 gradle.lockfile 與 verification-metadata。
 * 縮圖會存進使用者自己的 Firestore users 文件，所以要夠小：256px、約 20KB。
 *
 * 必須在 Activity 到達 STARTED 之前建立（[ComponentActivity.registerForActivityResult] 的限制），
 * 所以由 [FlutterChatActivity] 以欄位初始化建立，再交給 [BitchatFlutterChannels] 使用。
 */
class AvatarPhotoPicker(private val activity: ComponentActivity) {

    private var pendingResult: MethodChannel.Result? = null

    private val launcher = activity.registerForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri -> onPicked(uri) }

    fun pick(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("ALREADY_ACTIVE", "Photo picker is already open", null)
            return
        }
        pendingResult = result
        try {
            launcher.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
        } catch (e: Exception) {
            pendingResult = null
            result.error("NO_PICKER", e.message, null)
        }
    }

    private fun onPicked(uri: Uri?) {
        // Activity 被系統回收後重建時，結果會送到新的 launcher，但原本等待的 Dart 呼叫已經不在。
        val result = pendingResult ?: return
        pendingResult = null
        if (uri == null) {
            result.success(null) // 使用者取消
            return
        }
        activity.lifecycleScope.launch {
            val bytes = try {
                // 解碼大圖不能卡在主執行緒。
                withContext(Dispatchers.IO) { loadSquareJpeg(uri) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "Failed to process avatar photo", e)
                null
            }
            if (bytes != null) result.success(bytes)
            else result.error("DECODE_FAILED", "Could not read the selected photo", null)
        }
    }

    private fun loadSquareJpeg(uri: Uri): ByteArray? {
        val resolver = activity.contentResolver

        // 先只讀尺寸，算出取樣倍率，避免把上千萬像素的原圖整張載入記憶體。
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (minOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= OUTPUT_SIZE) sample *= 2

        val decoded = resolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: return null

        // 手機拍的照片常把方向寫在 EXIF 裡，不轉正的話頭像會躺著。
        val rotation = resolver.openInputStream(uri)?.use {
            when (ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } ?: 0f

        // 從中央裁成正方形，並在同一步完成旋轉與縮放。
        val side = minOf(decoded.width, decoded.height)
        val scale = OUTPUT_SIZE.toFloat() / side
        val matrix = Matrix().apply {
            postScale(scale, scale)
            postRotate(rotation)
        }
        val square = Bitmap.createBitmap(
            decoded,
            (decoded.width - side) / 2,
            (decoded.height - side) / 2,
            side,
            side,
            matrix,
            true
        )
        if (square !== decoded) decoded.recycle()

        return ByteArrayOutputStream().use { out ->
            square.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
            square.recycle()
            out.toByteArray()
        }
    }

    companion object {
        private const val TAG = "AvatarPhotoPicker"
        private const val OUTPUT_SIZE = 256
        private const val JPEG_QUALITY = 80
    }
}
