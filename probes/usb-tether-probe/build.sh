#!/usr/bin/env bash
# Builds build/usb-tether-probe.jar (dex) for app_process and runs the host-JVM self-test.
# No Gradle: javac (Android Studio JBR) + d8 against the installed android.jar.
set -euo pipefail
cd "$(dirname "$0")"

export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export PATH="$JAVA_HOME/bin:$PATH"  # d8 is a wrapper that needs java on PATH
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ANDROID_JAR=$(ls -d "$SDK"/platforms/android-*/android.jar | sort -V | tail -1)
D8=$(ls -d "$SDK"/build-tools/*/d8 | sort -V | tail -1)

rm -rf build && mkdir -p build/classes build/test
"$JAVA_HOME/bin/javac" --release 11 -Xlint:-options -classpath "$ANDROID_JAR" -d build/classes \
  $(find src -name '*.java')

# Self-test on the host JVM (Stats + errorName touch no android.* code at run time)
"$JAVA_HOME/bin/javac" --release 11 -classpath "build/classes:$ANDROID_JAR" -d build/test $(find test -name '*.java')
"$JAVA_HOME/bin/java" -cp "build/classes:build/test" dev.matebridge.probe.usbtether.StatsTest

"$D8" --min-api 29 --lib "$ANDROID_JAR" --output build/usb-tether-probe.jar $(find build/classes -name '*.class')
echo "built build/usb-tether-probe.jar"
