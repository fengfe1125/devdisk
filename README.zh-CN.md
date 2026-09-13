<p align="center">
  <img src="docs/icon-128.png" width="112" height="112" alt="DevDisk 图标">
</p>

<h1 align="center">DevDisk</h1>

<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong>
</p>

<p align="center">
  <strong>外置硬盘推不出去？DevDisk 告诉你是谁在用它，再帮你安全推出。</strong><br>
  给把 Android SDK、Gradle 缓存、Xcode 项目放在外置硬盘上的开发者做的 macOS 菜单栏小工具。
</p>

<p align="center">
  <a href="https://github.com/fengfe1125/devdisk/releases/latest"><img alt="最新版本" src="https://img.shields.io/github/v/release/fengfe1125/devdisk?display_name=tag&sort=semver&style=flat-square"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&logo=apple">
  <img alt="Apple 芯片" src="https://img.shields.io/badge/Apple%20silicon-arm64-111111?style=flat-square">
  <a href="LICENSE"><img alt="MIT 许可" src="https://img.shields.io/badge/license-MIT-111111?style=flat-square"></a>
</p>

<p align="center">
  <a href="https://github.com/fengfe1125/devdisk/releases/latest"><strong>下载最新版</strong></a>
</p>

## 它解决什么问题

如果你把开发环境放在外置硬盘上，下面这几件事大概都遇到过：

- **点「推出」，系统不让推。** 说磁盘正在被使用，可到底是谁在用，看不出来。罪魁祸首通常是还在后台跑的程序：Gradle、Kotlin 的后台进程，或者 adb。Android Studio 早就关了，它们还开着，在活动监视器里只显示成 `java` 或 `adb`，根本想不到是它们。
- **于是你点了「强制推出」，或者直接拔线。** 当时什么事都没有，下次编译却莫名其妙地报错：有个缓存文件写到一半被切断了。看起来像代码出了 bug，白白查半天。
- **想看看这块盘的情况，得敲一堆命令。** 还剩多少空间、空间被什么占了、硬盘健不健康、Time Machine 和 Spotlight 有没有在碰它。

## DevDisk 能做什么

- **菜单栏上直接看状态**：已连接、有问题要注意、正在推出，还是可以拔了。
- **找出是谁在用这块盘**：列出正在占用盘上文件的程序，分成「确认后能帮你关」和「需要你自己关」两类。
- **按正确的顺序安全推出**：你确认之后，它会请 Xcode、Android Studio 这类应用正常退出（没保存的内容照样会提醒你保存），停掉 Gradle、Kotlin 后台进程和 adb，然后推出硬盘，确认硬盘真的断开了，才告诉你可以拔线。
- **给盘做个体检**：剩余空间和空间都被什么占了、硬盘健康（剩余寿命、温度、异常断电次数）、有没有加密，以及 Time Machine、Spotlight、磁盘休眠这些设置会不会添乱。
- **提醒一个常见的坑**：盘没插的时候，提醒你别打开 Android Studio——它可能以为 SDK 丢了，把整套 SDK 重新下载到电脑自带的硬盘上。

<p align="center">
  <img src="docs/preview-short-light.png" width="380" alt="推出前的确认界面：列出要关掉的程序，等你确认（演示数据）">
  <br>
  <sub>推出前，DevDisk 会先列出要关掉什么，等你确认。（演示数据）</sub>
</p>

## 它不会做的事

- 不会强制关掉你的程序或后台服务，也不会强制推出硬盘。
- 不会因为名字对得上就关掉一个程序，只处理它亲眼看到正在占用这块盘的。
- 没检查清楚，不会说「没人在用」或「可以拔了」。检查失败或超时，会直接告诉你。
- 不碰系统进程和其他用户的进程。
- 不要管理员权限。需要改系统设置时，只给你一条能复制的命令，不替你执行。

模拟器、还在跑的编译、认不出来的程序，它都不会动，会提示你先自己处理。

## 安装

1. 从[最新版本](https://github.com/fengfe1125/devdisk/releases/latest)下载 zip，解压。
2. 把 `DevDisk.app` 拖进「应用程序」文件夹。
3. 第一次打开时，macOS 可能会拦住它，因为这个应用没有经过 Apple 公证。去 **系统设置 → 隐私与安全性**，点 **仍要打开**。

想看更详细的硬盘健康数据（剩余寿命、温度、通电时间），可以再装个 smartmontools。不装也能用，缺什么它会告诉你。

```bash
brew install smartmontools
```

**系统要求**：macOS 14 或更高版本，Apple 芯片的 Mac。

## 从源码构建

```bash
swift test
./package.sh -    # 构建 build/DevDisk.app，不会安装
```

## 更多细节

- [工作原理](docs/how-it-works.zh-CN.md)：推出的完整步骤、能查到什么查不到什么、怎么测试。
- [1.1.0 验收记录](docs/validation-1.1.0.md)

## 许可

[MIT](LICENSE)
