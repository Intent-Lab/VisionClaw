package com.meta.wearable.dat.externalsampleapps.cameraaccess.phone

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.ContactsContract
import android.provider.ContactsContract.Intents.Insert
import android.telephony.SmsManager
import androidx.core.content.ContextCompat
import com.meta.wearable.dat.externalsampleapps.cameraaccess.AppContextProvider
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolResult
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

class ContactActionManager {
    private val context
        get() = AppContextProvider.require()

    fun callContact(query: String): ToolResult {
        if (!hasContactsPermission()) {
            return ToolResult.Failure("전화번호부 권한이 없습니다. 연락처 권한을 허용한 뒤 다시 시도해주세요.")
        }
        if (!hasCallPermission()) {
            return ToolResult.Failure("전화 발신 권한이 없습니다. 전화 권한을 허용한 뒤 다시 시도해주세요.")
        }
        val matches = findMatches(query)
        if (matches.isEmpty()) {
            return ToolResult.Failure("전화번호부에서 '$query'에 해당하는 연락처를 찾지 못했습니다.")
        }
        if (matches.size > 1) {
            return ToolResult.Failure(
                "'$query'에 해당하는 연락처가 여러 명입니다: ${matches.take(3).joinToString(", ") { "${it.displayName} ${it.phoneNumber}" }}. 더 구체적으로 말씀해주세요."
            )
        }
        val match = matches.first()
        launchCallIntent(match.phoneNumber)
        return ToolResult.Success("${match.displayName}에게 전화를 걸었습니다.")
    }

    fun textContact(query: String, message: String): ToolResult {
        if (message.isBlank()) {
            return ToolResult.Failure("보낼 문자 내용을 함께 알려주세요.")
        }
        if (!hasContactsPermission()) {
            return ToolResult.Failure("전화번호부 권한이 없습니다. 연락처 권한을 허용한 뒤 다시 시도해주세요.")
        }
        if (!hasSmsPermission()) {
            return ToolResult.Failure("문자 전송 권한이 없습니다. SMS 권한을 허용한 뒤 다시 시도해주세요.")
        }
        val matches = findMatches(query)
        if (matches.isEmpty()) {
            return ToolResult.Failure("전화번호부에서 '$query'에 해당하는 연락처를 찾지 못했습니다.")
        }
        if (matches.size > 1) {
            return ToolResult.Failure(
                "'$query'에 해당하는 연락처가 여러 명입니다: ${matches.take(3).joinToString(", ") { "${it.displayName} ${it.phoneNumber}" }}. 더 구체적으로 말씀해주세요."
            )
        }
        val match = matches.first()
        sendSms(match.phoneNumber, message)
        return ToolResult.Success("${match.displayName}에게 문자를 보냈습니다.")
    }

    fun createContact(
        name: String,
        phone: String?,
        email: String?,
        org: String?,
        role: String?,
        notes: String?,
    ): ToolResult {
        if (name.isBlank()) {
            return ToolResult.Failure("저장할 연락처 이름을 알려주세요.")
        }
        val intent = Intent(ContactsContract.Intents.Insert.ACTION).apply {
            type = ContactsContract.RawContacts.CONTENT_TYPE
            putExtra(Insert.NAME, name)
            phone?.takeIf { it.isNotBlank() }?.let { putExtra(Insert.PHONE, it) }
            email?.takeIf { it.isNotBlank() }?.let { putExtra(Insert.EMAIL, it) }
            org?.takeIf { it.isNotBlank() }?.let { putExtra(Insert.COMPANY, it) }
            role?.takeIf { it.isNotBlank() }?.let { putExtra(Insert.JOB_TITLE, it) }
            notes?.takeIf { it.isNotBlank() }?.let { putExtra(Insert.NOTES, it) }
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
        return ToolResult.Success("$name 연락처 등록 화면을 열었습니다. 내용을 확인한 뒤 저장해주세요.")
    }

    fun searchContacts(query: String, limit: Int = 5): ToolResult {
        if (!hasContactsPermission()) {
            return ToolResult.Failure("전화번호부 권한이 없습니다. 연락처 권한을 허용한 뒤 다시 시도해주세요.")
        }
        if (query.isBlank()) {
            return ToolResult.Failure("검색할 연락처 이름을 알려주세요.")
        }
        val matches = findMatches(query).take(limit.coerceIn(1, 10))
        val candidates = JSONArray().apply {
            matches.forEachIndexed { index, match ->
                put(
                    JSONObject()
                        .put("rank", index + 1)
                        .put("display_name", match.displayName)
                        .put("phone_number", maskPhoneNumber(match.phoneNumber))
                )
            }
        }
        return ToolResult.Success(
            JSONObject()
                .put("query", query)
                .put("count", matches.size)
                .put("candidates", candidates)
                .toString()
        )
    }

    private fun maskPhoneNumber(value: String): String {
        val digits = value.filter { it.isDigit() }
        if (digits.length < 4) return value
        return value.replace(Regex("\\d(?=\\d{4})"), "*")
    }

    fun speechContextHint(limit: Int = 80): String {
        if (!hasContactsPermission()) return ""
        val names = linkedSetOf<String>()
        val projection = arrayOf(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
        context.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            projection,
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} IS NOT NULL",
            null,
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC",
        )?.use { cursor ->
            val displayNameIndex = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
            while (cursor.moveToNext() && names.size < limit) {
                val displayName = cursor.getString(displayNameIndex).orEmpty().trim()
                if (displayName.isNotBlank()) {
                    names.add(displayName)
                }
            }
        }
        if (names.isEmpty()) return ""
        return "연락처 이름 후보: ${names.joinToString(", ")}"
    }

    private fun hasContactsPermission(): Boolean =
        ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.READ_CONTACTS,
        ) == PackageManager.PERMISSION_GRANTED

    private fun hasCallPermission(): Boolean =
        ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.CALL_PHONE,
        ) == PackageManager.PERMISSION_GRANTED

    private fun hasSmsPermission(): Boolean =
        ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.SEND_SMS,
        ) == PackageManager.PERMISSION_GRANTED

    private fun findMatches(query: String): List<ContactMatch> {
        val normalizedQuery = normalize(query)
        if (normalizedQuery.isBlank()) return emptyList()

        val matches = linkedMapOf<String, ContactMatch>()
        val numberQuery = normalizeNumber(query)
        val selection = """
            ${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} IS NOT NULL
            AND (
                ${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ?
                OR ${ContactsContract.CommonDataKinds.Phone.NUMBER} LIKE ?
            )
        """.trimIndent()
        val args = arrayOf("%$query%", "%$query%")
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Phone.LOOKUP_KEY,
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            ContactsContract.CommonDataKinds.Phone.NUMBER,
        )

        context.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            projection,
            selection,
            args,
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC",
        )?.use { cursor ->
            val lookupKeyIndex = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.LOOKUP_KEY)
            val displayNameIndex = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
            val numberIndex = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.NUMBER)
            while (cursor.moveToNext()) {
                val displayName = cursor.getString(displayNameIndex).orEmpty().trim()
                val phoneNumber = cursor.getString(numberIndex).orEmpty().trim()
                if (displayName.isBlank() || phoneNumber.isBlank()) continue
                val normalizedName = normalize(displayName)
                val normalizedPhone = normalizeNumber(phoneNumber)
                if (
                    normalizedName.contains(normalizedQuery) ||
                    (numberQuery.isNotBlank() && normalizedPhone.contains(numberQuery))
                ) {
                    val lookupKey = cursor.getString(lookupKeyIndex).orEmpty()
                    matches.putIfAbsent(
                        "$lookupKey::$normalizedPhone",
                        ContactMatch(displayName, phoneNumber),
                    )
                }
            }
        }

        if (matches.isEmpty()) {
            collectAllContacts()
                .filter { contact ->
                    normalize(contact.displayName).contains(normalizedQuery) ||
                        normalizedQuery.contains(normalize(contact.displayName))
                }
                .forEach { contact ->
                    matches.putIfAbsent(
                        "${contact.displayName}::${normalizeNumber(contact.phoneNumber)}",
                        contact,
                    )
                }
        }

        val exactNameMatches = matches.values.filter { normalize(it.displayName) == normalizedQuery }
        return if (exactNameMatches.isNotEmpty()) exactNameMatches else matches.values.toList()
    }

    private fun collectAllContacts(): List<ContactMatch> {
        val contacts = linkedMapOf<String, ContactMatch>()
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Phone.LOOKUP_KEY,
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            ContactsContract.CommonDataKinds.Phone.NUMBER,
        )
        context.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            projection,
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} IS NOT NULL",
            null,
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC",
        )?.use { cursor ->
            val lookupKeyIndex = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.LOOKUP_KEY)
            val displayNameIndex = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
            val numberIndex = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.NUMBER)
            while (cursor.moveToNext()) {
                val displayName = cursor.getString(displayNameIndex).orEmpty().trim()
                val phoneNumber = cursor.getString(numberIndex).orEmpty().trim()
                if (displayName.isBlank() || phoneNumber.isBlank()) continue
                contacts.putIfAbsent(
                    "${cursor.getString(lookupKeyIndex).orEmpty()}::${normalizeNumber(phoneNumber)}",
                    ContactMatch(displayName, phoneNumber),
                )
            }
        }
        return contacts.values.toList()
    }

    private fun launchCallIntent(phoneNumber: String) {
        val intent = Intent(Intent.ACTION_CALL).apply {
            data = Uri.parse("tel:${Uri.encode(phoneNumber)}")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }

    private fun sendSms(phoneNumber: String, message: String) {
        val smsManager = context.getSystemService(SmsManager::class.java)
        val parts = smsManager.divideMessage(message)
        if (parts.size > 1) {
            smsManager.sendMultipartTextMessage(phoneNumber, null, parts, null, null)
        } else {
            smsManager.sendTextMessage(phoneNumber, null, message, null, null)
        }
    }

    private fun normalize(value: String): String =
        value.lowercase(Locale.getDefault()).replace("\\s+".toRegex(), "")

    private fun normalizeNumber(value: String): String =
        value.filter { it.isDigit() || it == '+' }

    private data class ContactMatch(
        val displayName: String,
        val phoneNumber: String,
    )
}
