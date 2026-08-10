package com.congodeveloperclub.opencongopay.sms

import java.io.File

internal enum class SmsCiphertextDomain { rules, inbox }

internal object SmsCiphertextInventory {
    private val inboxDirectories = listOf("inbox", "decisions", "decision-index")
    private val journalControls = listOf("decision-manifest.enc", "decision-pending.enc")

    fun exists(root: File): Boolean {
        return SmsCiphertextDomain.entries.any { domain -> exists(root, domain) } ||
            unclassifiedQuarantineExists(root)
    }

    fun exists(root: File, domain: SmsCiphertextDomain): Boolean {
        if (!root.exists()) return false
        val rootCiphertext = when (domain) {
            SmsCiphertextDomain.rules -> isCiphertext(File(root, "rules.enc"))
            SmsCiphertextDomain.inbox -> root.listFiles()?.any { file ->
                file.name != "rules.enc" && isCiphertext(file)
            } == true
        }
        if (rootCiphertext) return true
        if (domain == SmsCiphertextDomain.inbox && inboxDirectories.any { name ->
            File(root, name).listFiles()?.any(::isCiphertext) == true
        }) return true
        return File(root, "quarantine").listFiles()?.any { file ->
            file.name.startsWith("${domain.name}--") && isCiphertext(file)
        } == true
    }

    fun requireNoUnclassifiedQuarantine(root: File) {
        if (unclassifiedQuarantineExists(root)) throw LegacySmsMigrationRequiredException()
    }

    fun journalExists(root: File): Boolean {
        if (!root.exists()) return false
        if (journalControls.any { name -> isCiphertext(File(root, name)) }) return true
        if (listOf("decisions", "decision-index").any { name ->
                File(root, name).listFiles()?.any(::isCiphertext) == true
            }
        ) return true
        return File(root, "quarantine").listFiles()?.any { file ->
            file.name.startsWith("${SmsCiphertextDomain.inbox.name}--") && isCiphertext(file)
        } == true
    }

    private fun unclassifiedQuarantineExists(root: File): Boolean =
        File(root, "quarantine").listFiles()?.any { file ->
            isCiphertext(file) && SmsCiphertextDomain.entries.none { domain ->
                file.name.startsWith("${domain.name}--")
            }
        } == true

    private fun isCiphertext(file: File): Boolean =
        file.isFile && (file.name.endsWith(".enc") || file.name.contains(".enc."))
}

internal object LegacySmsStorageGuard {
    fun requireNoCiphertext(legacyRoot: File) {
        if (SmsCiphertextInventory.exists(legacyRoot)) {
            throw LegacySmsMigrationRequiredException()
        }
    }
}
