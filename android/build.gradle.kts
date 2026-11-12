allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
    // All plugins share the app's NDK. package:jni also needs an explicit
    // installed CMake instead of AGP's historical 3.10.2 default.
    project.afterEvaluate {
        project.extensions.findByType<com.android.build.gradle.LibraryExtension>()?.apply {
            ndkVersion = "27.1.12297006"
            if (project.name == "jni") {
                externalNativeBuild.cmake.version = "3.22.1"
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
