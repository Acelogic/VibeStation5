// Copyright (C) 2026 SharpEmu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

package com.mcruz.vibestation5.ui

import android.app.Activity
import android.graphics.BitmapFactory
import android.os.Build
import android.view.WindowInsets
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.Divider
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.mcruz.vibestation5.R
import com.mcruz.vibestation5.RuntimeViewModel
import com.mcruz.vibestation5.VibeStationState
import com.mcruz.vibestation5.data.Destination
import com.mcruz.vibestation5.data.Game
import com.mcruz.vibestation5.data.LogSeverity
import com.mcruz.vibestation5.data.MenuPresentation
import com.mcruz.vibestation5.data.MenuScreen
import com.mcruz.vibestation5.data.RuntimeStage
import com.mcruz.vibestation5.input.GuestAction
import java.text.DateFormat
import java.util.Date
import kotlin.math.roundToInt

private val VibeColors: ColorScheme = darkColorScheme(
    primary = Color(0xFF77E0A6),
    onPrimary = Color(0xFF002113),
    secondary = Color(0xFF8BAEFF),
    background = Color(0xFF050712),
    surface = Color(0xFF0D1222),
    surfaceVariant = Color(0xFF161D30),
    onBackground = Color(0xFFF4F6FF),
    onSurface = Color(0xFFF4F6FF),
    onSurfaceVariant = Color(0xFFB6BED3),
    error = Color(0xFFFF8A8A),
)

@Composable
fun VibeStationApp(model: RuntimeViewModel) {
    MaterialTheme(colorScheme = VibeColors) {
        val state = model.state
        val folderPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            uri?.let(model::addFolder)
        }
        Surface(
            Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.background,
            contentColor = MaterialTheme.colorScheme.onBackground,
        ) {
            BoxWithConstraints(Modifier.fillMaxSize()) {
                val wide = maxWidth >= 840.dp
                if (wide) {
                    Row(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
                        AppRail(state.destination, model::selectDestination)
                        VerticalDivider()
                        DestinationContent(
                            state = state,
                            model = model,
                            wide = true,
                            chooseFolder = { folderPicker.launch(null) },
                        )
                    }
                } else {
                    Scaffold(
                        bottomBar = { AppNavigationBar(state.destination, model::selectDestination) },
                        containerColor = MaterialTheme.colorScheme.background,
                    ) { padding ->
                        DestinationContent(
                            state = state,
                            model = model,
                            wide = false,
                            chooseFolder = { folderPicker.launch(null) },
                            modifier = Modifier.padding(padding).statusBarsPadding(),
                        )
                    }
                }
            }
        }
        state.errorMessage?.let { message ->
            AlertDialog(
                onDismissRequest = model::consumeError,
                confirmButton = { TextButton(onClick = model::consumeError) { Text("OK") } },
                title = { Text("VibeStation5") },
                text = { Text(message) },
            )
        }
    }
}

@Composable
private fun AppRail(selected: Destination, onSelected: (Destination) -> Unit) {
    NavigationRail(
        modifier = Modifier.width(128.dp).fillMaxHeight(),
        containerColor = Color(0xFF080B16),
        header = {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.padding(vertical = 20.dp),
            ) {
                Image(painterResource(R.mipmap.app_icon), null, Modifier.size(48.dp).clip(RoundedCornerShape(11.dp)))
                Text("VibeStation5", fontWeight = FontWeight.Bold, fontSize = 13.sp, modifier = Modifier.padding(top = 8.dp))
            }
        },
    ) {
        Destination.entries.forEach { destination ->
            NavigationRailItem(
                selected = destination == selected,
                onClick = { onSelected(destination) },
                icon = { Text(destination.label.take(1), fontWeight = FontWeight.Black) },
                label = { Text(destination.label) },
            )
        }
    }
}

@Composable
private fun AppNavigationBar(selected: Destination, onSelected: (Destination) -> Unit) {
    NavigationBar(containerColor = Color(0xFF080B16)) {
        Destination.entries.forEach { destination ->
            NavigationBarItem(
                selected = destination == selected,
                onClick = { onSelected(destination) },
                icon = { Text(destination.label.take(1), fontWeight = FontWeight.Black) },
                label = { Text(destination.label) },
            )
        }
    }
}

@Composable
private fun DestinationContent(
    state: VibeStationState,
    model: RuntimeViewModel,
    wide: Boolean,
    chooseFolder: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier.fillMaxSize()) {
        when (state.destination) {
            Destination.Library -> LibraryScreen(state, model, wide, chooseFolder)
            Destination.Runtime -> RuntimeScreen(state, model, wide)
            Destination.Settings -> SettingsScreen(state)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun LibraryScreen(
    state: VibeStationState,
    model: RuntimeViewModel,
    wide: Boolean,
    chooseFolder: () -> Unit,
) {
    Column(Modifier.fillMaxSize().padding(20.dp)) {
        ScreenHeader(
            title = "Game Library",
            subtitle = "Android Storage Access Framework folders",
        ) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = model::refreshLibrary, enabled = !state.isScanning) { Text("Refresh") }
                Button(onClick = chooseFolder) { Text("Add Folder") }
            }
        }
        Spacer(Modifier.height(16.dp))
        if (wide) {
            Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                FolderPanel(state, model, Modifier.width(290.dp).fillMaxHeight())
                GamePanel(state, model, Modifier.weight(1f).fillMaxHeight())
            }
        } else {
            Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                FolderPanel(state, model, Modifier.fillMaxWidth().height(180.dp))
                GamePanel(state, model, Modifier.fillMaxWidth().weight(1f))
            }
        }
    }
}

@Composable
private fun FolderPanel(state: VibeStationState, model: RuntimeViewModel, modifier: Modifier) {
    Panel(modifier) {
        Text("Folders", fontWeight = FontWeight.Bold, fontSize = 18.sp)
        Spacer(Modifier.height(8.dp))
        if (state.folders.isEmpty()) {
            EmptyMessage("Add a folder containing one or more eboot.bin files.")
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(state.folders, key = { it.uri }) { folder ->
                    Row(
                        Modifier.fillMaxWidth().background(Color.White.copy(alpha = 0.04f), RoundedCornerShape(10.dp)).padding(10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(folder.displayName, Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
                        TextButton(onClick = { model.removeFolder(folder.uri) }) { Text("Remove") }
                    }
                }
            }
        }
    }
}

@Composable
private fun GamePanel(state: VibeStationState, model: RuntimeViewModel, modifier: Modifier) {
    Panel(modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Detected Games", fontWeight = FontWeight.Bold, fontSize = 18.sp, modifier = Modifier.weight(1f))
            if (state.isScanning) CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
            else Text("${state.games.size}", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Spacer(Modifier.height(8.dp))
        if (state.games.isEmpty() && !state.isScanning) {
            EmptyMessage("No eboot.bin files have been discovered yet.")
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(state.games, key = Game::id) { game ->
                    GameRow(game, state.selectedGameId == game.id) { model.selectGame(game.id) }
                }
            }
        }
    }
}

@Composable
private fun GameRow(game: Game, selected: Boolean, onClick: () -> Unit) {
    val context = LocalContext.current
    val cover = remember(game.coverUri) {
        game.coverUri?.let { uri ->
            runCatching {
                context.contentResolver.openInputStream(android.net.Uri.parse(uri))?.use(BitmapFactory::decodeStream)
            }.getOrNull()
        }
    }
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(if (selected) MaterialTheme.colorScheme.secondary.copy(alpha = 0.19f) else Color.White.copy(alpha = 0.045f))
            .border(1.dp, if (selected) MaterialTheme.colorScheme.secondary else Color.Transparent, RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(64.dp).clip(RoundedCornerShape(10.dp)).background(Color(0xFF27314D)),
            contentAlignment = Alignment.Center,
        ) {
            if (cover != null) Image(cover.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            else Text(game.initials, fontWeight = FontWeight.Black, fontSize = 22.sp)
        }
        Column(Modifier.padding(start = 12.dp).weight(1f)) {
            Text(game.name, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                listOfNotNull(game.titleId, formatBytes(game.executableSize)).joinToString("  •  "),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 13.sp,
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun RuntimeScreen(state: VibeStationState, model: RuntimeViewModel, wide: Boolean) {
    var fullScreen by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().padding(20.dp)) {
        ScreenHeader(
            title = "Runtime",
            subtitle = model.selectedGame?.name ?: "Select a game from the library",
        ) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { fullScreen = true }) { Text("Full Screen") }
                OutlinedButton(
                    onClick = model::prepareSelectedGame,
                    enabled = model.selectedGame != null && state.stage != RuntimeStage.Preparing,
                ) { Text("Prepare") }
                Button(
                    onClick = if (state.demoActive) model::stopDemo else model::startInputAudioDemo,
                    enabled = state.preparation != null,
                ) { Text(if (state.demoActive) "Stop Demo" else "Input/Audio Demo") }
            }
        }
        Spacer(Modifier.height(14.dp))
        if (wide) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                GuestPanel(state, model, Modifier.weight(1.55f))
                RuntimeSummary(state, Modifier.weight(0.8f))
            }
        } else {
            GuestPanel(state, model, Modifier.fillMaxWidth())
            Spacer(Modifier.height(10.dp))
            RuntimeSummary(state, Modifier.fillMaxWidth())
        }
        Spacer(Modifier.height(12.dp))
        RuntimeConsole(state, model, Modifier.fillMaxWidth().weight(1f))
    }
    if (fullScreen) {
        FullScreenGuest(state, model, onDismiss = { fullScreen = false })
    }
}

@Composable
private fun GuestPanel(state: VibeStationState, model: RuntimeViewModel, modifier: Modifier) {
    Box(
        modifier.aspectRatio(16f / 9f).clip(RoundedCornerShape(15.dp)).background(Color.Black).border(
            1.dp,
            Color.White.copy(alpha = 0.18f),
            RoundedCornerShape(15.dp),
        ),
    ) {
        if (state.demoActive) {
            Image(
                painterResource(R.drawable.dreaming_sarah_menu),
                contentDescription = "Dreaming Sarah compatibility preview",
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Fit,
            )
            InteractiveMenu(state.menu, Modifier.align(Alignment.Center))
            TouchControls(model, Modifier.fillMaxSize())
        } else {
            Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(if (state.stage == RuntimeStage.Ready) "Android image ready" else "No Android guest frame", fontWeight = FontWeight.Bold)
                Text(
                    if (state.stage == RuntimeStage.Ready) "Start the input/audio compatibility demo." else "Prepare a PS4/PS5 SELF or decrypted ELF image.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 13.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(top = 5.dp),
                )
            }
        }
        Text(
            "${state.inputStatus}  •  ${state.audioStatus}",
            color = Color.White.copy(alpha = 0.65f),
            fontSize = 10.sp,
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 4.dp),
        )
    }
}

@Composable
private fun InteractiveMenu(menu: MenuPresentation, modifier: Modifier = Modifier) {
    Column(
        modifier.background(Color.Black.copy(alpha = 0.58f), RoundedCornerShape(8.dp)).padding(horizontal = 24.dp, vertical = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        menu.items.forEachIndexed { index, item ->
            val suffix = when {
                menu.screen == MenuScreen.Options && index == 0 -> "  ${(menu.musicVolume * 100).roundToInt()}%"
                menu.screen == MenuScreen.Options && index == 1 -> "  ${(menu.effectsVolume * 100).roundToInt()}%"
                else -> ""
            }
            Text(
                text = (if (index == menu.selectedIndex) "› " else "  ") + item + suffix,
                color = if (index == menu.selectedIndex) Color.White else Color.White.copy(alpha = 0.68f),
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
                fontWeight = if (index == menu.selectedIndex) FontWeight.Bold else FontWeight.Normal,
            )
        }
        menu.statusMessage?.let {
            Text(it, color = Color(0xFFFFC4E7), fontSize = 9.sp, modifier = Modifier.padding(top = 8.dp))
        }
    }
}

@Composable
private fun TouchControls(model: RuntimeViewModel, modifier: Modifier = Modifier) {
    Box(modifier.padding(10.dp)) {
        Column(Modifier.align(Alignment.BottomStart), horizontalAlignment = Alignment.CenterHorizontally) {
            ControlButton("▲") { model.input.touch(GuestAction.Up) }
            Row {
                ControlButton("◀") { model.input.touch(GuestAction.Left) }
                Spacer(Modifier.width(36.dp))
                ControlButton("▶") { model.input.touch(GuestAction.Right) }
            }
            ControlButton("▼") { model.input.touch(GuestAction.Down) }
        }
        Row(Modifier.align(Alignment.BottomEnd), verticalAlignment = Alignment.CenterVertically) {
            ControlButton("×", 46.dp) { model.input.touch(GuestAction.Back) }
            Spacer(Modifier.width(12.dp))
            ControlButton("○", 46.dp) { model.input.touch(GuestAction.Confirm) }
        }
        Row(Modifier.align(Alignment.TopCenter)) {
            ControlButton("L1") { model.input.touch(GuestAction.Left) }
            Spacer(Modifier.width(80.dp))
            ControlButton("OPTIONS", 58.dp) { model.input.touch(GuestAction.Options) }
            Spacer(Modifier.width(80.dp))
            ControlButton("R1") { model.input.touch(GuestAction.Right) }
        }
    }
}

@Composable
private fun ControlButton(label: String, diameter: androidx.compose.ui.unit.Dp = 34.dp, action: () -> Unit) {
    Box(
        Modifier
            .size(diameter)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.32f))
            .border(1.dp, Color.White.copy(alpha = 0.55f), CircleShape)
            .clickable(onClick = action),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = Color.White, fontSize = if (label.length > 3) 7.sp else 12.sp)
    }
}

@Composable
private fun RuntimeSummary(state: VibeStationState, modifier: Modifier) {
    Panel(modifier) {
        Text(state.stage.label, color = stageColor(state.stage), fontWeight = FontWeight.Bold, fontSize = 18.sp)
        Spacer(Modifier.height(10.dp))
        val report = state.preparation
        if (report == null) {
            EmptyMessage("Executable details appear here after preparation.")
        } else {
            SummaryRow("Format", report.format)
            SummaryRow("Entry point", "0x%016X".format(report.entryPoint))
            SummaryRow("Program headers", report.programHeaderCount.toString())
            SummaryRow("Loadable segments", report.loadableSegmentCount.toString())
            SummaryRow("Reserved memory", formatBytes(report.reservedMemoryBytes))
            SummaryRow("Encrypted", report.encryptedSegmentCount.toString())
            SummaryRow("Compressed", report.compressedSegmentCount.toString())
        }
    }
}

@Composable
private fun RuntimeConsole(state: VibeStationState, model: RuntimeViewModel, modifier: Modifier) {
    Panel(modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Runtime Console", fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            TextButton(onClick = model::clearLogs) { Text("Clear") }
        }
        HorizontalDivider(color = Color.White.copy(alpha = 0.09f))
        LazyColumn(Modifier.fillMaxSize().padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            items(state.logs) { line ->
                Row {
                    Text(
                        DateFormat.getTimeInstance(DateFormat.MEDIUM).format(Date(line.timestampMillis)),
                        color = Color(0xFF7E879F),
                        fontFamily = FontFamily.Monospace,
                        fontSize = 11.sp,
                        modifier = Modifier.width(94.dp),
                    )
                    Text(
                        line.severity.label,
                        color = severityColor(line.severity),
                        fontFamily = FontFamily.Monospace,
                        fontSize = 11.sp,
                        modifier = Modifier.width(52.dp),
                    )
                    Text(line.message, fontFamily = FontFamily.Monospace, fontSize = 11.sp)
                }
            }
        }
    }
}

@Composable
private fun SettingsScreen(state: VibeStationState) {
    LazyColumn(
        Modifier.fillMaxSize().padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item { ScreenHeader("Settings", "Android host and backend status") }
        item {
            SettingsCard("Android Host") {
                SummaryRow("OS", "Android ${Build.VERSION.RELEASE} / API ${Build.VERSION.SDK_INT}")
                SummaryRow("Device", "${Build.MANUFACTURER} ${Build.MODEL}")
                SummaryRow("ABIs", Build.SUPPORTED_ABIS.joinToString())
                SummaryRow("Input", state.inputStatus)
                SummaryRow("Audio", state.audioStatus)
            }
        }
        item {
            SettingsCard("Execution Backend") {
                StatusLine("SELF and ELF inspection", true)
                StatusLine("C++ loader through JNI", state.nativeBackend != "JNI unavailable")
                StatusLine("Persistent SAF library folders", true)
                StatusLine("Touch, keyboard, and gamepad", true)
                StatusLine("Android audio cues", true)
                StatusLine("x86-64 guest interpreter", false)
                StatusLine("GPU / guest video backend", false)
                Text(
                    "Android does not use the SideStore/StikDebug path. The current Android target is a native loader, preflight, input, audio, and UI port; guest CPU execution is still being ported from Swift.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(top = 10.dp),
                )
                Text(
                    "Native probe: ${state.nativeBackend}",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 12.sp,
                )
            }
        }
        item {
            SettingsCard("Controls") {
                Text("Gamepad: D-pad or left stick, A confirm, B back, Start options")
                Text("Keyboard: WASD/arrows, Enter/Space confirm, Escape back")
                Text("Touch: on-screen D-pad, face buttons, and options")
            }
        }
    }
}

@Composable
private fun FullScreenGuest(state: VibeStationState, model: RuntimeViewModel, onDismiss: () -> Unit) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        val view = LocalView.current
        DisposableEffect(Unit) {
            val window = (view.context as? Activity)?.window
            val controller = window?.let { WindowCompat.getInsetsController(it, view) }
            controller?.hide(WindowInsetsCompat.Type.systemBars())
            controller?.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            onDispose { controller?.show(WindowInsetsCompat.Type.systemBars()) }
        }
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            GuestPanel(state, model, Modifier.fillMaxSize())
            Button(onClick = onDismiss, modifier = Modifier.align(Alignment.TopEnd).padding(18.dp)) { Text("Exit Full Screen") }
        }
    }
}

@Composable
private fun ScreenHeader(
    title: String,
    subtitle: String? = null,
    actions: @Composable () -> Unit = {},
) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.Black, fontSize = 30.sp)
            subtitle?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
        actions()
    }
}

@Composable
private fun Panel(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Card(
        modifier,
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(Modifier.fillMaxSize().padding(15.dp), content = content)
    }
}

@Composable
private fun SettingsCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, fontWeight = FontWeight.Bold, fontSize = 19.sp)
            content()
        }
    }
}

@Composable
private fun SummaryRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
        Text(value, fontWeight = FontWeight.Medium, textAlign = TextAlign.End, modifier = Modifier.widthIn(max = 270.dp))
    }
}

@Composable
private fun StatusLine(label: String, available: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(if (available) "●" else "○", color = if (available) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error)
        Text(label, modifier = Modifier.padding(start = 9.dp))
    }
}

@Composable
private fun EmptyMessage(message: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(message, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
    }
}

@Composable
private fun VerticalDivider() {
    Box(Modifier.width(1.dp).fillMaxHeight().background(Color.White.copy(alpha = 0.09f)))
}

private fun formatBytes(bytes: Long): String = when {
    bytes >= 1024L * 1024 * 1024 -> "%.2f GB".format(bytes.toDouble() / (1024L * 1024 * 1024))
    bytes >= 1024L * 1024 -> "%.1f MB".format(bytes.toDouble() / (1024L * 1024))
    bytes >= 1024L -> "%.1f KB".format(bytes.toDouble() / 1024L)
    else -> "$bytes B"
}

private fun stageColor(stage: RuntimeStage): Color = when (stage) {
    RuntimeStage.Ready, RuntimeStage.InputDemo -> Color(0xFF77E0A6)
    RuntimeStage.Failed -> Color(0xFFFF8A8A)
    RuntimeStage.Preparing -> Color(0xFFFFD27A)
    RuntimeStage.Idle -> Color(0xFFB6BED3)
}

private fun severityColor(severity: LogSeverity): Color = when (severity) {
    LogSeverity.Success -> Color(0xFF77E0A6)
    LogSeverity.Warning -> Color(0xFFFFD27A)
    LogSeverity.Error -> Color(0xFFFF8A8A)
    LogSeverity.Debug -> Color(0xFF8BAEFF)
    LogSeverity.Info -> Color(0xFFB6BED3)
}
