package app.simbridge.android.net

import java.net.Inet4Address
import java.net.NetworkInterface

object NetUtil {
    private val skipPrefixes = listOf("rmnet", "r_rmnet", "v4-rmnet", "ccmni", "dummy", "lo", "p2p-dev", "ifb", "sit")

    /**
     * IPv4 addresses the iPhone could reach: Wi-Fi, hotspot, USB tethering, and VPN-mesh
     * (e.g. Tailscale 100.64/10) addresses. Mobile-data interfaces are excluded.
     */
    fun localAddresses(): List<String> = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback && skipPrefixes.none { p -> it.name.startsWith(p) } }
            .sortedBy { ifacePriority(it.name) }
            .flatMap { iface ->
                iface.inetAddresses.toList().filterIsInstance<Inet4Address>()
                    .filter { it.isSiteLocalAddress || isCgnat(it) }
                    .map { it.hostAddress ?: "" }
            }
            .filter { it.isNotEmpty() }
            .distinct()
    } catch (e: Exception) {
        emptyList()
    }

    private fun ifacePriority(name: String) = when {
        name.startsWith("wlan") -> 0
        name.startsWith("swlan") || name.startsWith("ap") -> 1
        name.startsWith("rndis") || name.startsWith("usb") -> 2
        else -> 3
    }

    private fun isCgnat(a: Inet4Address): Boolean {
        val b = a.address
        return (b[0].toInt() and 0xff) == 100 && (b[1].toInt() and 0xc0) == 64
    }
}
