package local.islet.link

import java.io.File
import java.math.BigInteger
import java.security.KeyPair
import java.security.interfaces.ECPublicKey
import java.security.spec.ECPrivateKeySpec
import local.islet.link.wire.LinkCipher
import local.islet.link.wire.LinkCrypto
import local.islet.link.wire.Message
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Same vectors as the Mac's `LinkTests.swift`: both sides must agree byte for byte. */
class WireTest {
    private val vectors: Map<String, String> = run {
        val text = File("../../Tests/IsletCoreTests/link-vectors.json").readText()
        Regex("\"(\\w+)\"\\s*:\\s*\"([0-9a-f]*)\"").findAll(text).associate { it.groupValues[1] to it.groupValues[2] }
    }

    private fun hex(key: String): ByteArray = vectors.getValue(key).chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun pairingMatchesTheMac() {
        val reference = LinkCrypto.keyPair()
        val params = (reference.public as ECPublicKey).params
        val phonePrivate = java.security.KeyFactory.getInstance("EC")
            .generatePrivate(ECPrivateKeySpec(BigInteger(1, hex("phonePrivate")), params))
        val phonePublic = LinkCrypto.publicKey(hex("phonePublic"), reference.public as ECPublicKey)
        val macPublic = LinkCrypto.publicKey(hex("macPublic"), reference.public as ECPublicKey)
        assertArrayEquals(hex("phonePublic"), LinkCrypto.x963(phonePublic))
        val shared = LinkCrypto.shared(KeyPair(phonePublic, phonePrivate), macPublic)
        assertArrayEquals(hex("shared"), shared)
        val pairing = LinkCrypto.pairing(shared, hex("macPublic"), hex("phonePublic"))
        assertArrayEquals(hex("secret"), pairing.secret)
        assertEquals(vectors["code"], pairing.code)
    }

    @Test fun sessionKeysAndCipherMatchTheMac() {
        val (macToPhone, phoneToMac) = LinkCrypto.session(hex("secret"), hex("macNonce"), hex("phoneNonce"))
        assertArrayEquals(hex("macToPhone"), macToPhone)
        assertArrayEquals(hex("phoneToMac"), phoneToMac)
        val opener = LinkCipher(macToPhone)
        assertEquals("hello", String(opener.open(hex("sealed0"))))
        assertEquals("hello", String(opener.open(hex("sealed1"))))
        val sealer = LinkCipher(macToPhone)
        assertArrayEquals(hex("sealed0"), sealer.seal("hello".toByteArray()))
    }

    @Test fun replayFails() {
        val key = ByteArray(32) { 7 }
        val frame = LinkCipher(key).seal("x".toByteArray())
        val opener = LinkCipher(key)
        opener.open(frame)
        assertTrue(runCatching { opener.open(frame) }.isFailure)
    }

    @Test fun readsTheMacsMessages() {
        val message = Message.decode(hex("message"))!!
        assertEquals("media.state", message.type)
        assertEquals("Song", message.json.getString("title"))
        assertTrue(message.json.getBoolean("playing"))
        assertArrayEquals(byteArrayOf(1, 2, 3), message.body)
        val round = Message.decode(Message.of("x", mapOf("a" to 1), byteArrayOf(9)).encoded())!!
        assertEquals(1, round.json.getInt("a"))
    }
}
