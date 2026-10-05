package com.bitchat.android.flutter

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * One bridge component's share of the `com.bitchat/bridge/methods` channel.
 *
 * Returns true when it claimed [call]; it then owns completing [result], now or later.
 * Returns false, without touching [result], for a method it does not own.
 */
fun interface BridgeMethodHandler {
    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean
}

/**
 * The single [MethodChannel.MethodCallHandler] behind the shared method channel.
 *
 * A BinaryMessenger keeps only the last handler set for a channel name, so bridge components
 * never register their own. They are chained here instead: each is offered the call in order,
 * the first to claim it answers, and a call nobody claims gets `notImplemented`. Every method
 * name must be owned by exactly one handler.
 */
class BridgeMethodDispatcher(
    private val handlers: List<BridgeMethodHandler>
) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (handlers.none { it.handle(call, result) }) {
            result.notImplemented()
        }
    }
}
