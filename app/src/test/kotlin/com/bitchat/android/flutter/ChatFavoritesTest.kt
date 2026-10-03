package com.bitchat.android.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Fixes upstream's favourite star rule as [ChatFavorites.status] reproduces it — the one rule
 * `MeshPeerListSheet.kt` applies in `PeopleSection` (`peerFavoriteStates`,
 * `peerTheyFavoritedUsStates`) and in `PrivateChatSheet` (`isFavorite`, `theyFavoritedUs`).
 */
class ChatFavoritesTest {

    private val lookedUp = mutableListOf<String>()

    private fun status(
        fingerprint: String?,
        favoritePeers: Set<String> = emptySet(),
        peerFavoritedUs: Set<String> = emptySet(),
        favoriteByID: Boolean = false,
        favoritedUsByID: Boolean = false
    ) = ChatFavorites.status(
        peerID = PEER,
        fingerprint = fingerprint,
        favoritePeers = favoritePeers,
        peerFavoritedUs = peerFavoritedUs,
        fallbacks = ChatFavorites.Fallbacks(
            isFavorite = { lookedUp += "isFavorite:$it"; favoriteByID },
            theyFavoritedUs = { lookedUp += "theyFavoritedUs:$it"; favoritedUsByID }
        )
    )

    @Test
    fun `a peer whose fingerprint is known is a favourite exactly when upstream's set has it`() {
        assertTrue(status(FINGERPRINT, favoritePeers = setOf(FINGERPRINT)).isFavorite)
        assertFalse(status(FINGERPRINT, favoritePeers = setOf(OTHER)).isFavorite)
    }

    @Test
    fun `with a known fingerprint the by-ID favourite lookup is not asked`() {
        // `if (fingerprint != null) favoritePeers.contains(fingerprint) else viewModel.isFavorite(peerID)`
        val result = status(FINGERPRINT, favoriteByID = true)

        assertFalse(result.isFavorite)
        assertFalse(lookedUp.any { it.startsWith("isFavorite") })
    }

    @Test
    fun `without a fingerprint upstream asks isFavorite by the peer's ID`() {
        assertTrue(status(fingerprint = null, favoriteByID = true).isFavorite)
        assertFalse(status(fingerprint = null, favoriteByID = false).isFavorite)
        assertTrue(lookedUp.all { it == "isFavorite:$PEER" || it.startsWith("theyFavoritedUs") })
    }

    @Test
    fun `they favourited us when upstream's set has the fingerprint`() {
        assertTrue(status(FINGERPRINT, peerFavoritedUs = setOf(FINGERPRINT)).theyFavoritedUs)
        assertFalse(status(FINGERPRINT, peerFavoritedUs = setOf(OTHER)).theyFavoritedUs)
    }

    @Test
    fun `or when the favourites store says so for the ID, fingerprint known or not`() {
        // `(fingerprint != null && peerFavoritedUs.contains(fingerprint)) ||
        //   favoriteRelationship?.theyFavoritedUs == true`
        assertTrue(status(FINGERPRINT, favoritedUsByID = true).theyFavoritedUs)
        assertTrue(status(fingerprint = null, favoritedUsByID = true).theyFavoritedUs)
        assertFalse(status(fingerprint = null).theyFavoritedUs)
    }

    @Test
    fun `the two directions are independent`() {
        assertEquals(
            ChatFavorites.Status(isFavorite = true, theyFavoritedUs = false),
            status(FINGERPRINT, favoritePeers = setOf(FINGERPRINT))
        )
        assertEquals(
            ChatFavorites.Status(isFavorite = false, theyFavoritedUs = true),
            status(FINGERPRINT, peerFavoritedUs = setOf(FINGERPRINT))
        )
        assertEquals(
            ChatFavorites.Status(isFavorite = true, theyFavoritedUs = true),
            status(FINGERPRINT, favoritePeers = setOf(FINGERPRINT), peerFavoritedUs = setOf(FINGERPRINT))
        )
    }

    private companion object {
        const val PEER = "1111111111111111"
        val FINGERPRINT = "f".repeat(64)
        val OTHER = "e".repeat(64)
    }
}
