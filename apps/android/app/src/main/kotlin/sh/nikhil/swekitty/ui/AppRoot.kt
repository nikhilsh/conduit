package sh.nikhil.swekitty.ui

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.rememberDrawerState
import androidx.compose.material3.DrawerValue
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.setValue
import kotlinx.coroutines.launch
import sh.nikhil.swekitty.SessionStore

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(store: SessionStore) {
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScopeCompat()
    var showSettings by remember { mutableStateOf(false) }

    val selectedId by store.selectedId.collectAsState()
    val sessions by store.sessions.collectAsState()
    val endpoint by store.endpoint.collectAsState()
    val connection by store.connection.collectAsState()

    // First-launch settings prompt.
    androidx.compose.runtime.LaunchedEffect(Unit) {
        if (!endpoint.isComplete) showSettings = true
        else if (connection is sh.nikhil.swekitty.ConnectionState.Disconnected) store.connect()
    }

    ModalNavigationDrawer(
        drawerState = drawerState,
        drawerContent = {
            ProjectListScreen(
                store = store,
                onOpenSettings = { showSettings = true },
                onCloseDrawer = { scope.launch { drawerState.close() } },
            )
        },
    ) {
        val selected = sessions.firstOrNull { it.id == selectedId }
        if (selected != null) {
            ProjectScreen(
                store = store,
                session = selected,
                onOpenDrawer = { scope.launch { drawerState.open() } },
            )
        } else {
            EmptyDetail(
                connection = connection,
                onOpenDrawer = { scope.launch { drawerState.open() } },
                onOpenSettings = { showSettings = true },
            )
        }
    }

    if (showSettings) {
        SettingsScreen(
            store = store,
            onDismiss = { showSettings = false },
        )
    }
}

// Small shim so this file doesn't pull androidx.compose.runtime.rememberCoroutineScope
// at every call site. Inlined to keep imports tidy.
@Composable
private fun rememberCoroutineScopeCompat() = androidx.compose.runtime.rememberCoroutineScope()
