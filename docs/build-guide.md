# 「自力」完整打包教程 & 踩坑记录

> 适用：Windows + Android。本仓库已是**完整可构建工程**（含 android/ 目录），
> 按本文走一遍即可从零打包出 APK。以下内容全部经过真机实测（vivo / Android 16）。

---

## 一、环境准备（一次性）

### 1. Flutter SDK
- 下载 stable 版 zip：<https://docs.flutter.dev/get-started/install/windows>
- 解压到**纯英文、无空格**路径（如 `D:\app\flutter`，不要放 `C:\Program Files`）
- 把 `D:\app\flutter\bin` 加入系统 PATH，重开终端验证：
  ```bash
  flutter --version     # 需要 3.38.1+（flutter_local_notifications 22 的要求）
  ```

### 2. Android 开发环境（二选一）
- **推荐**：安装 [Android Studio](https://developer.android.google.cn/studio)（国内可直连），
  首次启动向导会自动装好 Android SDK / Platform-Tools / Build-Tools，并自带 JDK
- 或只装 Android SDK Command-line Tools + Platform-Tools

### 3. 环境自检
```bash
flutter doctor                     # 确保 Android toolchain ✓
flutter doctor --android-licenses  # 接受许可（全部输入 y）
```

### 4. 需要的 SDK 组件（构建时也会自动补装）
| 组件 | 版本 | 说明 |
|---|---|---|
| platforms;android-36 | compileSdk 36 需要 | 缺了 Gradle 会自动下载 |
| build-tools | 36.0.0 | |
| **ndk** | **28.2.13676358** | ⚠️ Flutter 构建必需，见第五节踩坑 #2 |

> 中国网络提示：pub.dev 下载慢可挂代理；Gradle 发行包本工程已指向腾讯镜像
> （`android/gradle/wrapper/gradle-wrapper.properties` 里的 `mirrors.cloud.tencent.com`）。

---

## 二、获取代码并构建

```bash
git clone https://github.com/7iyxx/zili-pomodoro.git
cd zili-pomodoro
flutter pub get
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk（约 50MB，含四种 CPU 架构）
```

可选（体积更小的分架构包）：
```bash
flutter build apk --release --split-per-abi
# 产物：app-arm64-v8a-release.apk（多数现代手机用这个，约 20MB）
```

首次构建需要下载 Gradle / 依赖 / NDK，慢是正常的（10~20 分钟）；之后增量构建只要 1~5 分钟。

---

## 三、安卓关键配置（本仓库已配好，供排查参考）

### 1. AndroidManifest.xml（android/app/src/main/）
```xml
<!-- 权限：震动 / 通知 / 精确闹钟 ×2 / 开机重排 -->
<uses-permission android:name="android.permission.VIBRATE" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.USE_EXACT_ALARM" />
<uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />

<!-- <application> 内：flutter_local_notifications 的调度接收器（缺了后台到点不提醒） -->
<receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
<receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
    <intent-filter>
        <action android:name="android.intent.action.BOOT_COMPLETED"/>
        <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
        <action android:name="android.intent.action.QUICKBOOT_POWERON" />
        <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
    </intent-filter>
</receiver>
```

### 2. Core Library Desugaring（android/app/build.gradle.kts，必开）
```kotlin
android {
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
```

### 3. App 图标（脚本生成，可改）
- 图标与通知栏小图标由 `scripts/gen_icon.py` 生成（Pillow）
- 改配色：修改脚本里的 `GREEN_TOP` / `GREEN_BOTTOM` 后重跑 `python scripts/gen_icon.py`
- 自适应图标 XML：`android/app/src/main/res/mipmap-anydpi-v26/`

---

## 四、安装到手机

**方法 A：数据线（adb）**
```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```
（首次需在手机上开启「USB 调试」，并允许本电脑调试）

**方法 B：拷贝安装**
把 APK 传到手机（微信文件传输助手 / 数据线），文件管理器点击安装。
部分国产 ROM 需要在开发者选项里额外打开「USB 安装」等开关。

**装好后建议**：
- 允许**通知**权限；确认「闹钟和提醒」权限已开启
- 设置 → 应用 → 自力 → 电池策略 → **无限制**
- 不要在最近任务里强行划掉应用

---

## 五、踩坑记录（全部实测遇到并解决）

1. **旧版 cmdline-tools 的 sdkmanager 已弃用且会崩**（退出码 0xC0000409）：
   新版 cmdline-tools（16xxx 起）请改用 `android` CLI：
   ```bash
   # 例：安装 NDK
   "<SDK路径>/cmdline-tools/latest/bin/android.exe" sdk install "ndk;28.2.13676358"
   ```
2. **Flutter 构建必需 NDK 28.2.13676358**：缺失时报错类似
   `Package ndk not found ... Process 'sdkmanager.bat' finished with non-zero exit value`，
   用上一条的命令手动安装即可（约 2.2GB，装到 SDK/ndk/）。
3. **XML 注释里绝不能出现 `--`**（包括 `------` 装饰线）：
   会导致 `ManifestMerger2$MergeFailureException: Error parsing AndroidManifest.xml`。
   本仓库的 AndroidManifest 已避开此问题。
4. **git-bash 给 .bat 传含分号的参数要加 `MSYS_NO_PATHCONV=1`**：
   如 `MSYS_NO_PATHCONV=1 sdkmanager.bat "platforms;android-36"`，否则分号会被拆开、
   报 "Package platforms not found."
5. **Gradle 发行包走腾讯镜像更稳**（services.gradle.org 在国内慢）：
   已在 `android/gradle/wrapper/gradle-wrapper.properties` 中配置：
   ```
   distributionUrl=https\://mirrors.cloud.tencent.com/gradle/gradle-9.3.1-all.zip
   ```
6. **代理只影响 flutter / pub / curl**（靠环境变量），**Gradle daemon 不读环境变量**：
   Gradle 直连 `dl.google.com` / `mavenCentral` 一般可用；若个别仓库慢，
   可在 `android/gradle.properties` 追加：
   ```
   systemProp.https.proxyHost=127.0.0.1
   systemProp.https.proxyPort=7897
   ```
7. **构建中途不要修改工程文件**：Gradle 正在读取文件时修改会造成难查的解析失败，
   等构建结束再改。
8. **flutter doctor 的 Chrome / Visual Studio ✗ 可以忽略**（本项目只做安卓）。

---

## 六、验证清单（装好后测一遍）

1. 建一个任务（如"复习信号与系统"），点进去 → 计时页沿用它的参数 ✅
2. 把工作时长改成 1 分钟 → 开始 → 锁屏 → 到点是否响铃震动 ✅
3. 完成 1 个番茄 → 番茄计数 +1，自动切到短休息 ✅
4. 切到统计页 → 扇形图出现该任务，可切"今日 / 本周 / 本月" ✅
5. 打卡页添加一项 → 打勾 → 出现"连续 1 天" ✅
6. 杀掉 App 重新打开 → 数据全部还在 ✅
