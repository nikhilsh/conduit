pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // Termux (com.github.termux.termux-app) publishes terminal-view +
        // terminal-emulator as a multi-module JitPack build, not on Maven
        // Central. Scope JitPack to that group so it doesn't widen the
        // attack surface for other deps. See docs/PLAN-TERMINAL-REWRITE.md
        // ("Distribution: Maven Central; JitPack as fallback") — JitPack
        // turned out to be primary in practice because v0.118.3 isn't on
        // Maven Central.
        maven {
            url = uri("https://jitpack.io")
            content { includeGroup("com.github.termux.termux-app") }
        }
    }
}

rootProject.name = "Conduit"
include(":app")
