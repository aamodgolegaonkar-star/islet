package local.islet.link.wire

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.math.BigInteger
import java.nio.ByteBuffer
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject

/**
 * Islet Link's wire format, the same as the Mac's `Sources/IsletCore/Link.swift`.
 * `WireTest` checks it against `Tests/IsletCoreTests/link-vectors.json`.
 *
 * Frame: 4-byte big-endian length + payload. Payload before the handshake is a plain
 * message; after it, AES-256-GCM sealed (one key per direction, counter nonces).
 * Message: 4-byte big-endian header length + JSON header ("t" = type) + binary body.
 */
object Link {
    const val PORT = 47480
    const val SERVICE_TYPE = "_islet-link._tcp."
    const val VERSION = 1
    const val MAX_FRAME = 4 shl 20
    const val CHUNK = 512 shl 10
}

class Message(val header: ByteArray, val body: ByteArray = ByteArray(0)) {
    val json: JSONObject by lazy { runCatching { JSONObject(String(header, Charsets.UTF_8)) }.getOrDefault(JSONObject()) }
    val type: String get() = json.optString("t")

    fun encoded(): ByteArray {
        val out = ByteBuffer.allocate(4 + header.size + body.size)
        out.putInt(header.size)
        out.put(header)
        out.put(body)
        return out.array()
    }

    companion object {
        fun of(type: String, fields: Map<String, Any?> = emptyMap(), body: ByteArray = ByteArray(0)): Message {
            val json = JSONObject()
            json.put("t", type)
            for ((key, value) in fields) json.put(key, JSONObject.wrap(value))
            return Message(json.toString().toByteArray(Charsets.UTF_8), body)
        }

        fun decode(data: ByteArray): Message? {
            if (data.size < 4) return null
            val length = ByteBuffer.wrap(data, 0, 4).int
            if (length < 0 || length > data.size - 4) return null
            return Message(data.copyOfRange(4, 4 + length), data.copyOfRange(4 + length, data.size))
        }
    }
}

object Frames {
    fun frame(payload: ByteArray): ByteArray =
        ByteBuffer.allocate(4 + payload.size).putInt(payload.size).put(payload).array()

    /** Reads one frame, or throws at the end of the stream. */
    fun read(input: DataInputStream): ByteArray {
        val length = input.readInt()
        if (length < 0 || length > Link.MAX_FRAME) throw java.io.IOException("Frame too large")
        val bytes = ByteArray(length)
        input.readFully(bytes)
        return bytes
    }
}

object LinkCrypto {
    class Pairing(val secret: ByteArray, val code: String)

    private val random = SecureRandom()

    fun nonce(): ByteArray = ByteArray(32).also { random.nextBytes(it) }

    fun keyPair(): KeyPair = KeyPairGenerator.getInstance("EC").apply {
        initialize(ECGenParameterSpec("secp256r1"))
    }.generateKeyPair()

    /** X9.63 uncompressed point (65 bytes), as CryptoKit's `x963Representation`. */
    fun x963(key: ECPublicKey): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(4)
        out.write(fixed(key.w.affineX))
        out.write(fixed(key.w.affineY))
        return out.toByteArray()
    }

    fun publicKey(x963: ByteArray, like: ECPublicKey): ECPublicKey {
        require(x963.size == 65 && x963[0] == 4.toByte()) { "Bad key" }
        val point = ECPoint(BigInteger(1, x963.copyOfRange(1, 33)), BigInteger(1, x963.copyOfRange(33, 65)))
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, like.params)) as ECPublicKey
    }

    fun shared(pair: KeyPair, other: ECPublicKey): ByteArray =
        KeyAgreement.getInstance("ECDH").run {
            init(pair.private)
            doPhase(other, true)
            generateSecret()
        }

    fun pairing(shared: ByteArray, macKey: ByteArray, phoneKey: ByteArray): Pairing {
        val salt = macKey + phoneKey
        val secret = hkdf(shared, salt, "islet-link pair v1", 32)
        val sas = hkdf(shared, salt, "islet-link code v1", 4)
        val number = (ByteBuffer.wrap(sas).int.toLong() and 0xFFFFFFFFL) % 1_000_000
        return Pairing(secret, "%06d".format(number))
    }

    /** (macToPhone, phoneToMac). */
    fun session(secret: ByteArray, macNonce: ByteArray, phoneNonce: ByteArray): Pair<ByteArray, ByteArray> {
        val keys = hkdf(secret, macNonce + phoneNonce, "islet-link session v1", 64)
        return keys.copyOfRange(0, 32) to keys.copyOfRange(32, 64)
    }

    fun hkdf(input: ByteArray, salt: ByteArray, info: String, count: Int): ByteArray {
        val prk = hmac(salt, input)
        val out = ByteArrayOutputStream()
        var block = ByteArray(0)
        var counter = 1
        while (out.size() < count) {
            block = hmac(prk, block + info.toByteArray(Charsets.UTF_8) + byteArrayOf(counter.toByte()))
            out.write(block)
            counter++
        }
        return out.toByteArray().copyOf(count)
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(if (key.isEmpty()) ByteArray(32) else key, "HmacSHA256"))
            doFinal(data)
        }

    private fun fixed(value: BigInteger): ByteArray {
        val bytes = value.toByteArray()
        return when {
            bytes.size == 32 -> bytes
            bytes.size > 32 -> bytes.copyOfRange(bytes.size - 32, bytes.size)
            else -> ByteArray(32 - bytes.size) + bytes
        }
    }
}

/** One direction: AES-256-GCM, nonce = 4 zero bytes + 8-byte big-endian counter. */
class LinkCipher(key: ByteArray) {
    private val key = SecretKeySpec(key, "AES")
    private var counter = 0L

    @Synchronized
    fun seal(plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, nonce()))
        val out = cipher.doFinal(plain)
        counter++
        return out
    }

    /** The counter only moves on success, like the Mac's. */
    @Synchronized
    fun open(sealed: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, nonce()))
        val out = cipher.doFinal(sealed)
        counter++
        return out
    }

    private fun nonce(): ByteArray = ByteBuffer.allocate(12).putInt(0).putLong(counter).array()
}
