/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import java.util.Properties
import kotlin.io.path.div
import kotlin.io.path.exists
import kotlin.io.path.inputStream

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

val localProperties =
    Properties().apply {
      val localPropertiesPath = rootDir.toPath() / "local.properties"
      if (localPropertiesPath.exists()) {
        load(localPropertiesPath.inputStream())
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
        username =
            System.getenv("GITHUB_ACTOR")
                ?: localProperties.getProperty("github_username")
                ?: "blockchainMania"
        password = System.getenv("GITHUB_TOKEN") ?: localProperties.getProperty("github_token")
      }
    }
  }
}

rootProject.name = "CameraAccess"

include(":app")
