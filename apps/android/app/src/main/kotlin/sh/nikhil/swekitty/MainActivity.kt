package sh.nikhil.swekitty

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import sh.nikhil.swekitty.ui.AppRoot

class MainActivity : ComponentActivity() {
    private val store: SessionStore by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store.hydrate(applicationContext)
        setContent {
            MaterialTheme {
                Surface { AppRoot(store) }
            }
        }
    }
}
