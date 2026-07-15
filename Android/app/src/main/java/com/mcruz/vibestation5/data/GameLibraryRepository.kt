// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

package com.mcruz.vibestation5.data

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

class GameLibraryRepository(private val context: Context) {
    private val preferences = context.getSharedPreferences("vibestation5.library", Context.MODE_PRIVATE)
    private val resolver = context.contentResolver

    fun loadFolders(): List<LibraryFolder> {
        val encoded = preferences.getString(FOLDERS_KEY, null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(encoded)
            buildList {
                repeat(array.length()) { index ->
                    val item = array.getJSONObject(index)
                    add(LibraryFolder(item.getString("uri"), item.getString("name")))
                }
            }
        }.getOrDefault(emptyList())
    }

    fun addFolder(uri: Uri, existing: List<LibraryFolder>): List<LibraryFolder> {
        if (existing.any { it.uri == uri.toString() }) return existing
        val document = DocumentFile.fromTreeUri(context, uri)
        val folder = LibraryFolder(uri.toString(), document?.name ?: "Game Folder")
        return (existing + folder).sortedBy { it.displayName.lowercase() }.also(::saveFolders)
    }

    fun removeFolder(uri: String, existing: List<LibraryFolder>): List<LibraryFolder> =
        existing.filterNot { it.uri == uri }.also(::saveFolders)

    suspend fun scan(folders: List<LibraryFolder>): Pair<List<Game>, List<String>> = withContext(Dispatchers.IO) {
        val games = linkedMapOf<String, Game>()
        val issues = mutableListOf<String>()
        folders.forEach { folder ->
            val root = DocumentFile.fromTreeUri(context, Uri.parse(folder.uri))
            if (root == null || !root.exists() || !root.isDirectory) {
                issues += "${folder.displayName}: saved folder permission is unavailable."
            } else {
                runCatching { scanDirectory(root, folder, 0, games) }
                    .onFailure { issues += "${folder.displayName}: ${it.message ?: "scan failed"}" }
            }
        }
        games.values.sortedBy { it.name.lowercase() } to issues
    }

    private fun scanDirectory(
        directory: DocumentFile,
        folder: LibraryFolder,
        depth: Int,
        games: MutableMap<String, Game>,
    ) {
        if (depth > MAXIMUM_DEPTH) return
        val children = directory.listFiles()
        val executable = children.firstOrNull { it.isFile && it.name.equals("eboot.bin", ignoreCase = true) }
        if (executable != null) {
            val metadata = readMetadata(children.firstOrNull {
                it.isDirectory && it.name.equals("sce_sys", ignoreCase = true)
            })
            val cover = children.firstOrNull {
                it.isDirectory && it.name.equals("sce_sys", ignoreCase = true)
            }?.listFiles()?.firstOrNull {
                it.isFile && (it.name.equals("icon0.png", true) || it.name.equals("pic1.png", true))
            }
            val id = "${folder.uri}:${executable.uri}"
            games[id] = Game(
                id = id,
                rootUri = folder.uri,
                name = metadata.first ?: directory.name ?: "Unknown Game",
                titleId = metadata.second,
                executableUri = executable.uri.toString(),
                executableSize = executable.length(),
                coverUri = cover?.uri?.toString(),
            )
            return
        }
        children.filter(DocumentFile::isDirectory).forEach {
            scanDirectory(it, folder, depth + 1, games)
        }
    }

    private fun readMetadata(systemDirectory: DocumentFile?): Pair<String?, String?> {
        val param = systemDirectory?.listFiles()?.firstOrNull {
            it.isFile && it.name.equals("param.json", ignoreCase = true)
        } ?: return null to null
        return runCatching {
            val json = resolver.openInputStream(param.uri)?.bufferedReader()?.use { it.readText() }
                ?.let(::JSONObject) ?: return@runCatching null to null
            val titleId = json.optString("titleId").ifBlank {
                json.optString("contentId").takeIf(String::isNotBlank)?.substringBefore("-") ?: ""
            }.ifBlank { null }
            val localized = json.optJSONObject("localizedParameters")
            val language = localized?.optString("defaultLanguage")
            var title = language?.let { localized.optJSONObject(it)?.optString("titleName") }
                ?.ifBlank { null }
            if (title == null && localized != null) {
                val keys = localized.keys()
                while (keys.hasNext() && title == null) {
                    title = localized.optJSONObject(keys.next())?.optString("titleName")?.ifBlank { null }
                }
            }
            title to titleId
        }.getOrDefault(null to null)
    }

    private fun saveFolders(folders: List<LibraryFolder>) {
        val encoded = JSONArray().apply {
            folders.forEach { folder ->
                put(JSONObject().put("uri", folder.uri).put("name", folder.displayName))
            }
        }
        preferences.edit().putString(FOLDERS_KEY, encoded.toString()).apply()
    }

    private companion object {
        const val FOLDERS_KEY = "folders.v1"
        const val MAXIMUM_DEPTH = 8
    }
}
