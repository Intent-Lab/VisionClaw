import java.util.Properties

val localProperties = Properties().apply {
    val file = file("local.properties")
    if (file.exists()) {
        file.inputStream().use { load(it) }
    }
}

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
        maven {
            url = uri("https://maven.pkg.github.com/facebook/meta-wearables-dat-android")
            credentials {
                username = System.getenv("GITHUB_ACTOR")
                    ?: localProperties.getProperty("github_username")
                    ?: "blockchainMania"
                password = System.getenv("GITHUB_TOKEN")
                    ?: localProperties.getProperty("github_token")
                    ?: ""
            }
        }
        maven { url = uri("https://jitpack.io") }  // LiveKit 의존성
    }
}

rootProject.name = "FaceDetectionAPP"
include(":app")
