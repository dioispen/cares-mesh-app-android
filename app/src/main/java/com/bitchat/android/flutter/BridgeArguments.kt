package com.bitchat.android.flutter

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Reading a bridge method's arguments: Dart passes them as one map of named values. A call whose
 * arguments are not a map has none of them. Unlike `MethodCall.argument`, nothing here throws on
 * a value of the wrong type; it reads as missing, and the method answers [invalidArguments].
 */

/** The error code of a call whose arguments are missing or of the wrong type. */
internal const val INVALID_ARGUMENT = "INVALID_ARGUMENT"

/** The argument [key] when it is a String; null when it is absent, null or of another type. */
internal fun MethodCall.stringArgument(key: String): String? = (arguments as? Map<*, *>)?.get(key) as? String

/** Whether the optional String argument [key] is valid: absent, null, or a String. */
internal fun MethodCall.hasOptionalString(key: String): Boolean =
    (arguments as? Map<*, *>)?.get(key).let { it == null || it is String }

/** Answers [call] with [INVALID_ARGUMENT], naming the arguments it [expects], e.g. `{peerID: String}`. */
internal fun MethodChannel.Result.invalidArguments(call: MethodCall, expects: String) =
    error(INVALID_ARGUMENT, "${call.method} expects $expects", null)
