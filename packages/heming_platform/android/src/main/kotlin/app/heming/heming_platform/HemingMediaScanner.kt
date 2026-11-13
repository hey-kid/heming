package app.heming.heming_platform

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.OperationCanceledException
import android.provider.MediaStore
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Media discovery and copying have no audio focus or playback lifecycle. */
internal class HemingMediaScanner(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, PluginRegistry.RequestPermissionsResultListener {
    companion object {
        private const val PERMISSION_REQUEST = 0x484d
        private const val PAGE_SIZE = 200
    }

    private val channel = MethodChannel(messenger, "heming_media_scan")
    private val main = Handler(Looper.getMainLooper())
    private val queryWorker = Executors.newSingleThreadExecutor()
    private val copyWorker = Executors.newSingleThreadExecutor()
    private val previewCopyWorker = Executors.newSingleThreadExecutor()
    private var activityBinding: ActivityPluginBinding? = null
    private var attached = true
    private var pendingPermission: ScanSession? = null
    private var permissionDialogOpen = false
    @Volatile private var currentScan: ScanSession? = null
    @Volatile private var currentCopy: CopyJob? = null
    @Volatile private var currentPreviewCopy: CopyJob? = null

    init { channel.setMethodCallHandler(this) }

    private inner class Reply(private val result: MethodChannel.Result) {
        private val completed = AtomicBoolean(false)
        fun success(value: Any?) = deliver { result.success(value) }
        fun error(code: String, message: String) = deliver { result.error(code, message, null) }
        private fun deliver(action: () -> Unit) {
            if (!completed.compareAndSet(false, true)) return
            if (Looper.myLooper() == Looper.getMainLooper()) action() else main.post(action)
        }
    }

    private inner class ScanSession(val firstReply: Reply, val excludedPaths: List<String>) {
        val id = UUID.randomUUID().toString()
        val cancelled = AtomicBoolean(false)
        val signal = CancellationSignal()
        val warnings = linkedSetOf<String>()
        var cursor: Cursor? = null // Query worker only.
        var collectionIndex = 0
        var pageInFlight = false // Main thread only.
        var pageReply: Reply? = firstReply
        fun checkCancelled() { if (cancelled.get()) throw OperationCanceledException() }
        fun closeCursor() { cursor?.close(); cursor = null }
    }

    private inner class CopyJob(val reply: Reply) {
        // Main-thread waiters: cancellation completes only after file cleanup.
        val cancellationReplies = mutableListOf<Reply>()
        val cancelled = AtomicBoolean(false)
        val signal = CancellationSignal()
        val stream = AtomicReference<InputStream?>(null)
        fun cancel() {
            cancelled.set(true)
            signal.cancel()
            try { stream.getAndSet(null)?.close() } catch (_: Exception) { }
        }
        fun checkCancelled() { if (cancelled.get()) throw OperationCanceledException() }
    }

    private data class SourceStat(val size: Long, val modifiedMs: Long)
    private class SourceChanged : Exception()

    fun attachActivity(binding: ActivityPluginBinding) {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        if (pendingPermission == null) permissionDialogOpen = false
    }

    fun detachActivity(forConfigurationChange: Boolean) {
        currentPreviewCopy?.cancel()
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        // No Dart call may wait forever when its permission Activity disappears.
        pendingPermission?.let { cancelSession(it) }
        pendingPermission = null
        if (!forConfigurationChange) permissionDialogOpen = false
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        permissionDialogOpen = false
        val session = pendingPermission
        pendingPermission = null
        if (session != null && !session.cancelled.get() && attached) readPage(session, session.firstReply)
        return true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val reply = Reply(result)
        if (!attached) { reply.error("scan_unavailable", "媒体扫描已关闭"); return }
        when (call.method) {
            "scan" -> beginScan(call.argument<Boolean>("requestPermission") == true,
                call.argument<List<String>>("excludedPaths").orEmpty(), reply)
            "scanNext" -> {
                val session = currentScan
                if (session == null || session.id != call.argument<String>("scanId") || session.cancelled.get()) {
                    reply.error("scan_cancelled", "扫描已结束，请刷新列表")
                } else if (session.pageInFlight || pendingPermission === session) {
                    reply.error("scan_busy", "扫描正在进行")
                } else readPage(session, reply)
            }
            "cancelScan" -> {
                val id = call.argument<String>("scanId")
                currentScan?.takeIf { id == null || it.id == id }?.let { cancelSession(it) }
                reply.success(null)
            }
            "copyMedia" -> beginCopy(call, reply)
            "cancelCopy" -> { currentCopy?.cancel(); reply.success(null) }
            "copyPreviewMedia" -> beginCopy(call, reply, preview = true)
            "cancelPreviewCopy" -> {
                val job = currentPreviewCopy
                if (job == null) reply.success(null) else {
                    job.cancellationReplies.add(reply)
                    job.cancel()
                }
            }
            "openMedia" -> openMedia(call, reply)
            else -> result.notImplemented()
        }
    }

    private fun hasPermission(permission: String) =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun audioAccess(): String = if (
        hasPermission(if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_AUDIO
        else Manifest.permission.READ_EXTERNAL_STORAGE)
    ) "full" else "denied"

    private fun videoAccess(): String {
        if (Build.VERSION.SDK_INT < 33) return audioAccess()
        if (hasPermission(Manifest.permission.READ_MEDIA_VIDEO)) return "full"
        if (Build.VERSION.SDK_INT >= 34 && hasPermission(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)) return "partial"
        return "denied"
    }

    private fun permissionsToRequest(): Array<String> {
        if (Build.VERSION.SDK_INT < 33) return if (audioAccess() == "full") emptyArray()
            else arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        val permissions = mutableListOf<String>()
        if (audioAccess() != "full") permissions.add(Manifest.permission.READ_MEDIA_AUDIO)
        if (videoAccess() != "full") {
            permissions.add(Manifest.permission.READ_MEDIA_VIDEO)
            if (Build.VERSION.SDK_INT >= 34) permissions.add(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        }
        return permissions.toTypedArray()
    }

    private fun beginScan(requestPermission: Boolean, excludedPaths: List<String>, reply: Reply) {
        currentScan?.let { cancelSession(it) }
        val excluded = (excludedPaths + context.filesDir.path + context.cacheDir.path)
            .mapNotNull { try { File(it).canonicalPath.trimEnd('/') } catch (_: Exception) { null } }
        val session = ScanSession(reply, excluded)
        currentScan = session
        val permissions = if (requestPermission) permissionsToRequest() else emptyArray()
        if (permissions.isEmpty()) { readPage(session, reply); return }
        val activity: Activity? = activityBinding?.activity
        if (activity == null || activity.isFinishing || activity.isDestroyed) {
            currentScan = null
            reply.error("scan_activity", "请回到和鸣后开启媒体扫描")
            return
        }
        if (permissionDialogOpen) {
            currentScan = null
            reply.error("scan_busy", "请先完成系统媒体权限选择")
            return
        }
        pendingPermission = session
        permissionDialogOpen = true
        try {
            activity.requestPermissions(permissions, PERMISSION_REQUEST)
        } catch (_: Exception) {
            pendingPermission = null
            permissionDialogOpen = false
            session.warnings.add("无法打开媒体授权，请检查系统权限设置")
            readPage(session, reply)
        }
    }

    private fun cancelSession(session: ScanSession) {
        session.cancelled.set(true)
        session.signal.cancel()
        session.pageReply?.error("scan_cancelled", "扫描已取消")
        session.pageReply = null
        if (pendingPermission === session) pendingPermission = null
        if (currentScan === session) currentScan = null
        queryWorker.execute { session.closeCursor() }
    }

    private fun readPage(session: ScanSession, reply: Reply) {
        session.pageInFlight = true
        session.pageReply = reply
        queryWorker.execute {
            try {
                val items = ArrayList<Map<String, Any>>(PAGE_SIZE)
                while (items.size < PAGE_SIZE && session.collectionIndex < 2) {
                    session.checkCancelled()
                    val isAudio = session.collectionIndex == 0
                    val category = if (isAudio) "audio" else "video"
                    val access = if (isAudio) audioAccess() else videoAccess()
                    if (access == "denied") {
                        session.closeCursor()
                        session.collectionIndex++
                        continue
                    }
                    val collection = if (isAudio) MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                        else MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                    try {
                        if (session.cursor == null) session.cursor = queryCollection(collection, session.signal)
                        val cursor = session.cursor
                        if (cursor == null || !cursor.moveToNext()) {
                            session.closeCursor()
                            session.collectionIndex++
                            continue
                        }
                        val id = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID))
                        val size = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE))
                        val name = cursor.getString(cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME))
                        if (id < 0 || size <= 0 || name.isNullOrBlank()) continue
                        // DATA is only an exclusion/display hint. The file is
                        // always opened through its authorized content URI.
                        @Suppress("DEPRECATION")
                        val sourcePath = cursor.getString(cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATA))
                        if (sourcePath != null && session.excludedPaths.any {
                            sourcePath == it || sourcePath.startsWith("$it/")
                        }) continue
                        val uri = ContentUris.withAppendedId(collection, id).toString()
                        val modified = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED))
                        val duration = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION))
                        val folder = if (Build.VERSION.SDK_INT >= 29) {
                            cursor.getString(cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.RELATIVE_PATH)).orEmpty().trimEnd('/')
                        } else {
                            sourcePath?.let { File(it).parentFile?.name }.orEmpty()
                        }
                        items.add(mapOf("sourceId" to uri, "locator" to uri,
                            "name" to name.take(1024), "category" to category, "sizeBytes" to size,
                            "modifiedMs" to (modified.coerceAtLeast(0) * 1000),
                            "durationMs" to duration.coerceAtLeast(0), "folder" to folder.take(1024)))
                    } catch (error: SecurityException) {
                        session.closeCursor()
                        session.collectionIndex++
                        session.warnings.add(if (isAudio) "音频读取权限已变化，请重新授权或刷新" else "视频读取权限已变化，请重新授权或刷新")
                    } catch (error: OperationCanceledException) {
                        throw error
                    } catch (_: Exception) {
                        session.closeCursor()
                        session.collectionIndex++
                        session.warnings.add(if (isAudio) "部分音频暂时无法读取，可尝试手动添加" else "部分视频暂时无法读取，可尝试手动添加")
                    }
                }
                session.checkCancelled()
                val data = mapOf("items" to items, "scanId" to session.id,
                    "hasMore" to (session.collectionIndex < 2),
                    "audioAccess" to audioAccess(), "videoAccess" to videoAccess(),
                    "warnings" to session.warnings.toList())
                main.post {
                    session.pageInFlight = false
                    session.pageReply = null
                    if (session.cancelled.get()) reply.error("scan_cancelled", "扫描已取消") else reply.success(data)
                }
            } catch (_: OperationCanceledException) {
                session.closeCursor()
                reply.error("scan_cancelled", "扫描已取消")
            } catch (_: Exception) {
                session.closeCursor()
                reply.error("scan_failed", "无法读取本机媒体，请刷新或手动添加")
            }
        }
    }

    private fun queryCollection(uri: Uri, signal: CancellationSignal): Cursor? {
        val projection = mutableListOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_MODIFIED, MediaStore.Audio.Media.DURATION)
        if (Build.VERSION.SDK_INT >= 29) projection.add(MediaStore.MediaColumns.RELATIVE_PATH)
        @Suppress("DEPRECATION")
        projection.add(MediaStore.MediaColumns.DATA)
        val selection = mutableListOf("${MediaStore.MediaColumns.SIZE} > 0")
        if (Build.VERSION.SDK_INT >= 29) selection.add("${MediaStore.MediaColumns.IS_PENDING} = 0")
        if (Build.VERSION.SDK_INT >= 30) selection.add("${MediaStore.MediaColumns.IS_TRASHED} = 0")
        return context.contentResolver.query(uri, projection.toTypedArray(), selection.joinToString(" AND "),
            null, "${MediaStore.MediaColumns.DATE_ADDED} DESC, ${MediaStore.MediaColumns._ID} DESC", signal)
    }

    private fun mediaUri(value: String?): Uri {
        val uri = value?.let(Uri::parse) ?: throw IllegalArgumentException()
        val parts = uri.pathSegments
        require(uri.scheme == "content" && uri.authority == MediaStore.AUTHORITY &&
            parts.size == 4 && parts[1] in setOf("audio", "video") && parts[2] == "media" &&
            (parts[3].toLongOrNull() ?: -1) >= 0 && uri.query == null && uri.fragment == null)
        return uri
    }

    private fun sourceStat(uri: Uri, signal: CancellationSignal): SourceStat {
        context.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_MODIFIED),
            null, null, null, signal)?.use { cursor ->
            if (cursor.moveToFirst()) return SourceStat(cursor.getLong(0), cursor.getLong(1).coerceAtLeast(0) * 1000)
        }
        throw SourceChanged()
    }

    private fun openMedia(call: MethodCall, reply: Reply) {
        val activity = activityBinding?.activity
        if (activity == null || activity.isFinishing || activity.isDestroyed) {
            reply.error("open_activity", "请回到和鸣后打开文件")
            return
        }
        try {
            val uri = mediaUri(call.argument<String>("locator"))
            val category = uri.pathSegments[1]
            // Query only the authorized item. A MIME lookup does not decode it.
            sourceStat(uri, CancellationSignal())
            val reportedType = context.contentResolver.getType(uri)
            val mime = reportedType?.takeIf { it.startsWith("$category/") } ?: "$category/*"
            val view = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = ClipData.newRawUri("媒体文件", uri)
            }
            if (view.resolveActivity(context.packageManager) == null) {
                reply.error("open_unavailable", "没有可打开此文件的播放器")
                return
            }
            activity.startActivity(Intent.createChooser(view, "用其他播放器打开").apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = view.clipData
            })
            reply.success(null)
        } catch (_: ActivityNotFoundException) {
            reply.error("open_unavailable", "没有可打开此文件的播放器")
        } catch (_: SecurityException) {
            reply.error("open_permission", "无法读取该媒体，请重新授权或刷新列表")
        } catch (_: SourceChanged) {
            reply.error("source_changed", "文件已变化或不再存在，请刷新扫描列表")
        } catch (_: Exception) {
            reply.error("open_failed", "无法打开该媒体，请刷新列表后重试")
        }
    }

    private fun beginCopy(call: MethodCall, reply: Reply, preview: Boolean = false) {
        if ((if (preview) currentPreviewCopy else currentCopy) != null) {
            reply.error("copy_busy", if (preview) "正在准备试听，请稍后重试" else "正在加入其他资源")
            return
        }
        val uri: Uri
        val destination: File
        val expectedSize = call.argument<Number>("expectedSize")?.toLong()
        val expectedModified = call.argument<Number>("expectedModifiedMs")?.toLong()
        try {
            uri = mediaUri(call.argument<String>("uri"))
            if (preview) require(uri.pathSegments[1] == "audio")
            destination = File(requireNotNull(call.argument<String>("destination"))).canonicalFile
            val allowedRoots = if (preview) listOf(context.cacheDir.canonicalPath)
                else listOf(context.filesDir.canonicalPath, context.cacheDir.canonicalPath)
            require(allowedRoots.any { destination.path.startsWith("$it/") } && expectedSize != null && expectedSize > 0 &&
                expectedModified != null && expectedModified >= 0)
        } catch (_: Exception) { reply.error("copy_arguments", "媒体复制参数无效"); return }
        val job = CopyJob(reply)
        if (preview) currentPreviewCopy = job else currentCopy = job
        (if (preview) previewCopyWorker else copyWorker).execute {
            var created = false
            var completed = false
            var failureCode = "copy_failed"
            var failureMessage = if (preview) "无法准备试听，请检查文件和剩余空间"
                else "无法加入该资源，请检查文件和剩余空间"
            try {
                job.checkCancelled()
                val before = sourceStat(uri, job.signal)
                if (before.size != expectedSize || before.modifiedMs != expectedModified) throw SourceChanged()
                if (!destination.createNewFile()) throw IllegalArgumentException("destination exists")
                created = true
                val asset = context.contentResolver.openAssetFileDescriptor(uri, "r", job.signal)
                    ?: throw SourceChanged()
                asset.use {
                    asset.createInputStream().use { input ->
                        job.stream.set(input)
                        try {
                            FileOutputStream(destination).use { output ->
                                val buffer = ByteArray(128 * 1024)
                                var copied = 0L
                                while (true) {
                                    job.checkCancelled()
                                    val count = input.read(buffer)
                                    if (count < 0) break
                                    copied += count
                                    if (copied > before.size) throw SourceChanged()
                                    output.write(buffer, 0, count)
                                }
                                job.checkCancelled()
                                if (copied != before.size) throw SourceChanged()
                            }
                        } finally { job.stream.compareAndSet(input, null) }
                    }
                }
                if (sourceStat(uri, job.signal) != before) throw SourceChanged()
                job.checkCancelled()
                completed = true
            } catch (_: SourceChanged) {
                failureCode = "source_changed"
                failureMessage = "文件已变化或不再存在，请刷新扫描列表"
            } catch (_: SecurityException) {
                failureCode = "copy_permission"
                failureMessage = "无法读取该媒体，请重新授权或手动添加"
            } catch (_: Exception) {
                // Cancellation can surface as an IO error after closing the stream.
            } finally {
                if (!completed && created) destination.delete()
                main.post {
                    if (preview) {
                        if (currentPreviewCopy === job) currentPreviewCopy = null
                    } else if (currentCopy === job) currentCopy = null
                    // Cancellation may arrive after the copy worker finishes but
                    // before its completion callback runs on the main thread.
                    if (preview && job.cancelled.get()) {
                        if (created) destination.delete()
                        reply.error("copy_cancelled", "已取消试听")
                    } else if (completed) reply.success(null)
                    else if (job.cancelled.get()) reply.error("copy_cancelled", "已取消加入")
                    else reply.error(failureCode, failureMessage)
                    job.cancellationReplies.forEach { it.success(null) }
                    job.cancellationReplies.clear()
                }
            }
        }
    }

    fun dispose() {
        if (!attached) return
        currentScan?.let { cancelSession(it) }
        currentCopy?.cancel()
        currentPreviewCopy?.cancel()
        detachActivity(false)
        attached = false
        channel.setMethodCallHandler(null)
        queryWorker.shutdown()
        copyWorker.shutdown()
        previewCopyWorker.shutdown()
    }
}
